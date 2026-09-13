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
