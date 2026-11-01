variable "aws_region" {
  description = "Regiao AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome estavel do projeto e do cluster EKS"
  type        = string
  default     = "oficina360"
}

variable "environment" {
  description = "Ambiente implantado"
  type        = string
  default     = "lab"
}

variable "kubernetes_version" {
  description = "Versao do Kubernetes aceita pelo Learner Lab"
  type        = string
  default     = "1.36"
}

variable "node_instance_types" {
  description = "Tipos de instancia aceitos pelo node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  description = "Quantidade minima de nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size deve ser maior ou igual a 1."
  }
}

variable "node_max_size" {
  description = "Quantidade maxima de nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size deve ser maior ou igual a node_min_size."
  }
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes"
  type        = number
  default     = 1

  validation {
    condition = (
      var.node_desired_size >= var.node_min_size &&
      var.node_desired_size <= var.node_max_size
    )
    error_message = "node_desired_size deve estar entre node_min_size e node_max_size."
  }
}

variable "vpc_cidr" {
  description = "CIDR da VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets publicas"
  type        = list(string)
  default     = ["10.42.0.0/20", "10.42.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Informe pelo menos duas subnets para o EKS."
  }
}

variable "allowed_cidr" {
  description = "CIDR autorizado a acessar o endpoint publico do EKS"
  type        = string
  default     = "0.0.0.0/0"
}

variable "eks_cluster_role_arn" {
  description = "ARN da role preexistente da conta atual para o cluster EKS"
  type        = string

  validation {
    condition = can(regex(
      "^arn:aws:iam::[0-9]{12}:role/.+$",
      var.eks_cluster_role_arn
    ))
    error_message = "Informe um ARN IAM Role valido para o cluster EKS."
  }
}

variable "eks_node_role_arn" {
  description = "ARN da role preexistente da conta atual para o node group EKS"
  type        = string

  validation {
    condition = can(regex(
      "^arn:aws:iam::[0-9]{12}:role/.+$",
      var.eks_node_role_arn
    ))
    error_message = "Informe um ARN IAM Role valido para o node group EKS."
  }
}
