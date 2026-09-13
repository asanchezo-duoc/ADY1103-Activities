provider "aws" {
  region = var.aws_region

  # AWS Academy Learner Lab entrega credenciales TEMPORALES (STS) que incluyen un
  # session token y expiran al cerrar la sesion del lab. Por eso aqui no se declara
  # ninguna credencial: se toman de las variables de entorno
  #   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
  # que se copian del panel "AWS Details" del lab (ver README.md, seccion 3).
  #
  # NUNCA escribir las llaves en un archivo .tf: quedan en el repositorio.

  default_tags {
    tags = {
      Proyecto   = var.project_name
      Asignatura = "ADY1103"
      Gestionado = "Terraform"
    }
  }
}
