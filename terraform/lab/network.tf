locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs            = local.azs
  public_subnets = var.public_subnet_cidrs

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.project_name}" = "shared"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
