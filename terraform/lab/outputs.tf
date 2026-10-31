output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value     = aws_eks_cluster.main.endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "subnet_ids" {
  value = module.vpc.public_subnets
}

output "database_access_security_group_id" {
  value = aws_security_group.database_access.id
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "vpc_id" {
  description = "ID da VPC"
  value       = module.vpc.vpc_id
}

output "lambda_security_group_id" {
  description = "Security Group utilizado pela Lambda"
  value       = aws_security_group.database_access.id
}

output "lambda_subnet_ids" {
  description = "Subnets utilizadas pela Lambda"
  value       = module.vpc.private_subnets
}

output "eks_cluster_name" {
  description = "Nome do cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint do cluster EKS"
  value       = aws_eks_cluster.main.endpoint
  sensitive   = true
}

output "eks_cluster_ca" {
  description = "Certificate Authority do cluster EKS"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}