# ---------------------------------------------------------------------------
# Instancias EC2
#
# Un solo recurso con for_each cubre las dos topologias: en "completa" crea una
# maquina por plataforma del caso, y en "compacta" crea una sola con todas.
# El mapa que decide esto vive en locals.tf.
#
# Cada servidor recibe las direcciones de TODOS los demas, porque las IP
# privadas se fijan por adelantado. Sin eso, Terraform tendria que leer la IP de
# una instancia para poder construir otra del mismo recurso, que es una
# referencia circular imposible de resolver.
# ---------------------------------------------------------------------------

locals {
  subnet_ids = sort(data.aws_subnets.default.ids)

  # Security Group que corresponde a cada rol.
  sg_de_rol = {
    "aplicacion"    = aws_security_group.app.id
    "base-de-datos" = aws_security_group.datos.id
    "borde"         = aws_security_group.borde.id
  }
}

resource "aws_instance" "servidor" {
  for_each = local.servidores

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  private_ip                  = local.ips[each.key]
  vpc_security_group_ids      = [local.sg_de_rol[each.value.rol]]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/scripts/user_data_servidor.sh.tftpl", {
    project_name = var.project_name
    perfiles     = each.value.perfiles
    region       = var.aws_region
    bucket       = aws_s3_bucket.documentos.bucket
    objeto       = aws_s3_object.demo.key

    db_host     = local.db_host
    db_name     = var.db_name
    db_user     = var.db_username
    db_password = var.db_password
    admin_token = var.admin_token

    web_host    = local.host_de["web"]
    web_port    = local.puertos["web"]
    stock_host  = local.host_de["stock"]
    stock_port  = local.puertos["stock"]
    agenda_host = local.host_de["agenda"]
    agenda_port = local.puertos["agenda"]
    crm_host    = local.host_de["crm"]
    crm_port    = local.puertos["crm"]
    pagos_host  = local.host_de["pagos"]
    pagos_port  = local.puertos["pagos"]
  })

  # Si cambia el script de arranque, la instancia se recrea. Es lo correcto en
  # un laboratorio: el user_data solo se ejecuta en el primer arranque, asi que
  # sin esto una edicion no tendria ningun efecto.
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 obligatorio
  }

  tags = {
    Name     = "${var.project_name}-${each.key}"
    Rol      = each.value.rol
    Perfiles = each.value.perfiles
  }

  # El contenido del entorno debe estar en el bucket antes de que la maquina
  # intente descargarlo.
  depends_on = [aws_s3_object.demo]
}

# ---------------------------------------------------------------------------
# Stack de monitoreo de referencia (opcional)
# ---------------------------------------------------------------------------
resource "aws_instance" "monitoreo" {
  count = var.enable_monitoring ? 1 : 0

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.monitoreo[0].id]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/scripts/user_data_monitoring.sh.tftpl", {
    project_name     = var.project_name
    grafana_password = var.grafana_admin_password
    borde_ip         = local.ips["borde"]
    # Se arma el bloque YAML de targets ya indentado, para que el archivo de
    # Prometheus quede valido.
    targets_plataformas = join("\n", [
      for plataforma, puerto in local.puertos :
      "      - targets: [\"${local.host_de[plataforma]}:${puerto}\"]\n        labels:\n          plataforma: \"${plataforma}\""
    ])
  })

  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.project_name}-monitoreo"
    Rol  = "monitoreo"
  }
}
