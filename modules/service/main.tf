data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# Untagged layers accumulate on every rebuild and ECR only gives 500 MB free.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public entry point for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Reach tasks on the ECS ephemeral port range"
  ip_protocol                  = "tcp"
  from_port                    = 32768
  to_port                      = 65535
  referenced_security_group_id = var.instance_security_group_id
}

# The only way in to a container host. Tasks use bridge networking with a dynamic
# host port, so the range rather than a single port — and sourced from the load
# balancer's security group, so nothing else on the internet can reach a task
# even though the hosts sit in a public subnet.
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = var.instance_security_group_id
  description                  = "Load balancer to tasks on the ephemeral port range"
  ip_protocol                  = "tcp"
  from_port                    = 32768
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  idle_timeout               = 60

  tags = var.tags
}

resource "aws_lb_target_group" "this" {
  name        = var.name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # 30s is the default and it means a deploy waits half a minute per task doing
  # nothing. These are containers on the same host, not cross-region calls.
  deregistration_delay = 15

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Task IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Stops this role being assumable on behalf of a task in someone else's account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# AWS publishes AmazonECSTaskExecutionRolePolicy for this, but it grants ecr:*
# read on every repository in the account and logs write on every group. This is
# the same set of actions scoped to the one repository and the one log group.
data "aws_iam_policy_document" "execution" {
  statement {
    sid    = "EcrAuth"
    effect = "Allow"
    # GetAuthorizationToken is account-level and cannot be scoped to a repository.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullThisImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]

    resources = [aws_ecr_repository.this.arn]
  }

  statement {
    sid    = "WriteThisLogGroup"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  description        = "Used by the ECS agent to pull the image and create log streams"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-and-log"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Separate from the execution role and deliberately empty: this is what the
# application itself can do, and right now it calls no AWS API. Attach policies
# here — never to the execution role — when that changes.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  description        = "Assumed by the application container itself"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Task definition and service
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family             = var.name
  network_mode       = "bridge"
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = var.name
      image = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
      cpu   = var.task_cpu
      # Hard limit. The task is killed if it exceeds this, which is the point:
      # one leaking container should not take the host and its neighbours down.
      memory    = var.task_memory
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          # 0 makes ECS assign a host port from the ephemeral range, so two
          # copies of the task can run on one host during a rolling deploy.
          hostPort = 0
          protocol = "tcp"
        }
      ]

      environment = [
        for k, v in var.environment : { name = k, value = v }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # Container-level check as well as the load balancer's. This one catches a
      # process that is up but wedged, before the ALB has drained its interval.
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }

      linuxParameters = {
        initProcessEnabled = true # reap zombies; without it PID 1 ignores SIGTERM
      }

      readonlyRootFilesystem = false
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
    base              = 0
  }

  # 100/200 lets a replacement task start before the old one is drained, given
  # the host has room. With one t3.micro and 256 MiB tasks, it does.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Without this a bad image sits in a crash loop until someone notices.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60
  wait_for_steady_state             = true

  tags = var.tags

  # The listener must exist before the service registers targets, and the target
  # group is only usable once attached to the load balancer.
  depends_on = [aws_lb_listener.http]

  lifecycle {
    # The CI pipeline deploys by registering a new task definition revision.
    # Terraform owns the shape of the service, not which build is live.
    ignore_changes = [task_definition, desired_count]
  }
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name}-unhealthy-targets"
  alarm_description   = "At least one target has been failing its health check for two minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = aws_lb_target_group.this.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  tags = var.tags
}

# Alarms on the ratio, not the count. A fixed count of 5xx means one thing at ten
# requests a minute and something else entirely at ten thousand.
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name}-5xx-rate"
  alarm_description   = "More than 5% of requests returned 5xx from the application over five minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "100 * (errors / IF(requests > 0, requests, 1))"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"

      dimensions = {
        TargetGroup  = aws_lb_target_group.this.arn_suffix
        LoadBalancer = aws_lb.this.arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"

      dimensions = {
        TargetGroup  = aws_lb_target_group.this.arn_suffix
        LoadBalancer = aws_lb.this.arn_suffix
      }
    }
  }

  tags = var.tags
}
