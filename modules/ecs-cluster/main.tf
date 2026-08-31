resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

# Resolved at plan time from the SSM public parameter, so a new AMI is picked up
# by re-running Terraform rather than by editing a hardcoded ID that silently rots.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_iam_policy_document" "instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json

  tags = var.tags
}

# The ECS agent's own permissions: register the instance with the cluster, poll
# for tasks, report state. AWS owns this policy and keeps it current.
resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager instead of SSH. No key pair, no port 22 in any security group,
# and every session is logged in CloudTrail.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name

  tags = var.tags
}

resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "Container hosts for the ${var.name} ECS cluster"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-instance" })

  lifecycle {
    create_before_destroy = true
  }
}

# Outbound only. Nothing may reach these hosts except through a rule added by the
# service module, which opens the ephemeral port range to the load balancer alone.
resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "Pull images from ECR, reach the ECS control plane, ship logs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip
    security_groups             = [aws_security_group.instance.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only. Blocks the SSRF-to-credential-theft path that IMDSv1 leaves open.
    http_tokens = "required"
    # 2 rather than 1: containers on a bridge network are one hop from the host.
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = false # detailed monitoring is billed per instance; basic is free
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config
    # Reclaim disk from exited containers and unreferenced images. A t3.micro
    # root volume fills up surprisingly fast under a few weeks of deploys.
    echo "ECS_IMAGE_CLEANUP_INTERVAL=30m" >> /etc/ecs/ecs.config
    echo "ECS_IMAGE_MINIMUM_CLEANUP_AGE=1h" >> /etc/ecs/ecs.config
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-node" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = "${var.name}-"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  health_check_type         = "EC2"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # Required for the capacity provider to manage this group.
  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
    }
  }

  lifecycle {
    create_before_destroy = true

    # Managed scaling owns this number once the capacity provider is attached;
    # leaving it in the diff would make Terraform fight the scaler on every plan.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "this" {
  name = "${var.name}-asg"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.this.arn

    # Requires protect_from_scale_in on the ASG, which makes instances awkward to
    # delete by hand. Not worth it at this size.
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
    base              = 0
  }
}
