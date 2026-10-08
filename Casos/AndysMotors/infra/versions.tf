terraform {
  # Terraform 1.5+ por los bloques de validacion de variables y templatefile().
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Se fija la version mayor para que un cambio del proveedor no rompa la
      # actividad a mitad de semestre. Si se sube, revisar primero el changelog.
      version = "~> 5.70"
    }
  }
}
