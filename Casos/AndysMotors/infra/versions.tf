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
    archive = {
      source = "hashicorp/archive"
      # Empaqueta la carpeta demo/ para subirla a S3, desde donde cada servidor
      # la descarga al arrancar.
      version = "~> 2.4"
    }
  }
}
