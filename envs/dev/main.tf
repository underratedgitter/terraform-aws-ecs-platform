locals {
  name = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  az_count           = 2
  enable_nat_gateway = var.enable_nat_gateway
  enable_flow_logs   = false
}

module "cluster" {
  source = "../../modules/ecs-cluster"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.workload_subnet_ids

  # Public subnets and no NAT means the host reaches ECR over its own public IP.
  associate_public_ip = module.network.workload_needs_public_ip

  instance_type    = var.instance_type
  min_size         = 1
  max_size         = 2
  desired_capacity = 1
}

module "service" {
  source = "../../modules/service"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  cluster_id                 = module.cluster.cluster_id
  capacity_provider_name     = module.cluster.capacity_provider_name
  instance_security_group_id = module.cluster.instance_security_group_id

  container_port    = var.container_port
  image_tag         = var.image_tag
  desired_count     = var.desired_count
  health_check_path = var.health_check_path

  task_cpu    = 256
  task_memory = 256

  environment = {
    NODE_ENV = var.environment
    PORT     = tostring(var.container_port)
  }
}
