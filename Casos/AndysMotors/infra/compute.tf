# ---------------------------------------------------------------------------
# Instancias EC2
#
# Las seis cajas del diagrama del caso (sitio web, CRM, stock, agendamiento,
# pagos y base de datos) NO necesitan seis instancias: corren como contenedores
# sobre una sola maquina. Eso mantiene el laboratorio dentro del presupuesto y
# del limite de instancias del Learner Lab.
# ---------------------------------------------------------------------------

locals {
  # Se ordenan los IDs para que el subnet elegido sea siempre el mismo entre
  # ejecuciones: aws_subnets devuelve un conjunto sin orden garantizado.
  subnet_ids = sort(data.aws_subnets.default.ids)

  # Destino de la base de datos que se le entrega a la aplicacion: el endpoint
  # de RDS cuando existe, o el contenedor "db" de la propia instancia cuando no.
  db_host = var.enable_rds ? aws_db_instance.main[0].address : "db"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/scripts/user_data_app.sh.tftpl", {
    project_name = var.project_name
    use_rds      = var.enable_rds
    db_host      = local.db_host
    db_name      = var.db_name
    db_user      = var.db_username
    db_password  = var.db_password
  })

  # Cambiar el script de arranque recrea la instancia. Es lo correcto en un
  # laboratorio: el user_data solo se ejecuta en el primer arranque, asi que sin
  # esto una edicion del template no tendria ningun efecto visible.
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
    Name = "${var.project_name}-app"
    Rol  = "aplicacion"
  }
}

resource "aws_instance" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.monitoring[0].id]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/scripts/user_data_monitoring.sh.tftpl", {
    project_name     = var.project_name
    app_private_ip   = aws_instance.app.private_ip
    grafana_password = var.grafana_admin_password
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
    Name = "${var.project_name}-monitoring"
    Rol  = "monitoreo"
  }
}
