output "cluster_name" {
  description = "Nome atual do cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint atual do cluster EKS; use apenas para diagnostico"
  value       = aws_eks_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca" {
  description = "CA atual do cluster EKS; use apenas para diagnostico"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "vpc_id" {
  description = "ID da VPC"
  value       = module.vpc.vpc_id
}

output "subnet_ids" {
  description = "Subnets publicas usadas pelo EKS e pelos recursos do laboratorio"
  value       = module.vpc.public_subnets
}

output "database_access_security_group_id" {
  description = "Security Group compartilhado para acesso ao PostgreSQL"
  value       = aws_security_group.database_access.id
}

output "lambda_security_group_id" {
  description = "Security Group utilizado pela Lambda"
  value       = aws_security_group.database_access.id
}

output "lambda_subnet_ids" {
  description = "Subnets utilizadas pela Lambda no desenho atual do laboratorio"
  value       = module.vpc.public_subnets
}

output "configure_kubectl" {
  description = "Comando informativo; as pipelines usam resolve-eks-runtime.sh"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
