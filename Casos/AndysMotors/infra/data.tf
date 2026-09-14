# ---------------------------------------------------------------------------
# Recursos que YA EXISTEN en la cuenta del Learner Lab.
#
# Aqui esta la diferencia mas importante respecto de un Terraform "normal":
# el lab deniega por politica la creacion de roles, usuarios y politicas de IAM
# (iam:CreateRole, iam:CreateUser, iam:CreatePolicy). Por eso este proyecto no
# crea NINGUN recurso de IAM: consume los que el lab ya provee.
#
# Esta es tambien la razon por la que casi ningun modulo publico del Terraform
# Registry sirve en el Learner Lab: practicamente todos crean roles por dentro.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Perfil de instancia preexistente del lab. Permite que las EC2 hablen con otros
# servicios de AWS (S3, CloudWatch) sin crear un rol propio.
data "aws_iam_instance_profile" "lab" {
  name = "LabInstanceProfile"
}

# Se usa la VPC por defecto en vez de crear una.
# Motivos: menos permisos involucrados, creacion casi instantanea, nada que
# destruir despues, y se evita la tentacion de un NAT Gateway (que es caro y se
# come el presupuesto del lab en pocas horas).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# AMI mas reciente de Amazon Linux 2023 (x86_64), publicada por Amazon.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# CIDR de la subred elegida, necesario para calcular las IP privadas fijas de
# cada servidor (ver locals.tf).
data "aws_subnet" "elegida" {
  id = local.subnet_ids[0]
}
