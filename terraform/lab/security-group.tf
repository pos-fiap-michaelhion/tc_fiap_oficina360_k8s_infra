resource "aws_security_group" "database_access" {
  name        = "${var.project_name}-database-access"
  description = "Acesso ao PostgreSQL a partir da VPC e da Lambda"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name        = "${var.project_name}-database-access"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgresql_from_vpc" {
  security_group_id = aws_security_group.database_access.id
  description       = "PostgreSQL a partir da VPC"

  cidr_ipv4   = module.vpc.vpc_cidr_block
  ip_protocol = "tcp"
  from_port   = 5432
  to_port     = 5432
}

resource "aws_vpc_security_group_ingress_rule" "postgresql_self" {
  security_group_id = aws_security_group.database_access.id
  description       = "PostgreSQL entre recursos associados ao mesmo SG"

  referenced_security_group_id = aws_security_group.database_access.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "database_access_all" {
  security_group_id = aws_security_group.database_access.id
  description       = "Saida liberada para os recursos associados ao SG"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
