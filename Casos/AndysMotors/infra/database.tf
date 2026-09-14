# ---------------------------------------------------------------------------
# Amazon RDS PostgreSQL (OPCIONAL - apagado por defecto)
#
# Ver la explicacion completa en la variable enable_rds. En resumen: RDS tarda
# entre 10 y 15 minutos en crearse, que es donde suelen expirar las credenciales
# temporales del Learner Lab, y es el recurso que mas presupuesto consume.
#
# Ojo con una consecuencia de encenderlo: la instancia de aplicacion necesita el
# endpoint de RDS para configurarse, asi que Terraform esperara a que la base de
# datos termine de crearse antes de levantar la EC2.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  count = var.enable_rds ? 1 : 0

  name = "${var.project_name}-db-subnets"
  # RDS exige subredes en al menos dos zonas de disponibilidad distintas, aunque
  # la instancia no sea Multi-AZ. La VPC por defecto trae una por zona.
  subnet_ids = local.subnet_ids

  tags = { Name = "${var.project_name}-db-subnets" }
}

resource "aws_db_instance" "main" {
  count = var.enable_rds ? 1 : 0

  identifier     = "${var.project_name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name = aws_db_subnet_group.main[0].name
  # Se reutiliza el Security Group de datos: las reglas son las mismas tanto si
  # la base corre en RDS como si corre en el contenedor de ServerData.
  vpc_security_group_ids = [aws_security_group.datos.id]

  # La base de datos nunca se expone a Internet: solo la alcanza la instancia de
  # aplicacion, a traves del Security Group.
  publicly_accessible = false
  multi_az            = false

  # Ajustes propios de un laboratorio efimero: sin respaldos, sin snapshot final
  # y sin proteccion de borrado, para que "terraform destroy" termine limpio y
  # no queden respaldos consumiendo presupuesto despues de la clase.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Name = "${var.project_name}-db"
    Rol  = "base-de-datos"
  }
}
