# ---------------------------------------------------------------------------
# Amazon S3: archivos, documentos, imagenes de vehiculos, respaldos y reportes.
#
# El nombre de un bucket es global en todo AWS, asi que se le agrega el ID de la
# cuenta del lab para evitar colisiones con otros alumnos.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "documentos" {
  bucket = "${var.project_name}-docs-${data.aws_caller_identity.current.account_id}"

  # El lab se destruye al final de cada clase: se permite borrar el bucket
  # aunque tenga objetos dentro, para que "terraform destroy" no se atasque.
  force_destroy = true

  tags = {
    Name = "${var.project_name}-documentos"
    Rol  = "almacenamiento"
  }
}

# Sin esto, una politica mal escrita podria dejar documentos de clientes
# accesibles desde Internet. Es la proteccion mas barata del proyecto.
resource "aws_s3_bucket_public_access_block" "documentos" {
  bucket = aws_s3_bucket.documentos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "documentos" {
  bucket = aws_s3_bucket.documentos.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documentos" {
  bucket = aws_s3_bucket.documentos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# Distribucion del entorno de Andys Motors a los servidores
#
# Cada servidor necesita el codigo del entorno (las aplicaciones, el
# docker-compose y la configuracion de HAProxy). Se empaqueta la carpeta demo/
# y se sube al bucket; el script de arranque de cada maquina lo descarga con la
# CLI de AWS, usando el perfil de instancia del laboratorio.
#
# Se descarta clonar el repositorio desde las instancias: obligaria a que fuera
# publico. Y se descarta incrustar el codigo en el user_data: AWS lo limita a
# 16 KB y el entorno es bastante mas grande.
# ---------------------------------------------------------------------------

data "archive_file" "demo" {
  type        = "zip"
  source_dir  = "${path.module}/../demo"
  output_path = "${path.module}/.terraform/tmp/demo.zip"

  # Ojo con como funcionan las exclusiones de este proveedor: comparan rutas
  # exactas, NO patrones. Poner "app/node_modules" no excluye su contenido. Por
  # eso las carpetas se enumeran archivo por archivo con fileset(), que si
  # entiende comodines. Sin esto, un "npm install" local hecho por error subiria
  # miles de archivos al bucket en cada apply.
  excludes = concat(
    [".env", ".gitignore", "README.md"],
    [for f in fileset("${path.module}/../demo", "app/node_modules/**") : f],
    [for f in fileset("${path.module}/../demo", "scripts/__pycache__/**") : f],
  )
}

resource "aws_s3_object" "demo" {
  bucket = aws_s3_bucket.documentos.id
  key    = "entorno/demo.zip"
  source = data.archive_file.demo.output_path

  # Cuando cambia el contenido del entorno, cambia el etag y Terraform vuelve a
  # subirlo. Los servidores lo descargan de nuevo en su proximo arranque.
  etag = data.archive_file.demo.output_md5
}
