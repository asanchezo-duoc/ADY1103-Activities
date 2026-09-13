# ---------------------------------------------------------------------------
# Security Groups
#
# Se referencian entre si por ID (no por IP): asi las reglas siguen siendo
# validas aunque las instancias cambien de IP privada al reiniciar el lab.
# ---------------------------------------------------------------------------

# --- Instancia de aplicacion (sitio web, CRM, pagos y base de datos) ---------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Aplicacion Andys Motors: web publica, SSH de administracion y scraping de metricas"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = var.allow_public_web ? "Sitio web publico" : "Sitio web, solo administracion"
  cidr_ipv4         = var.allow_public_web ? "0.0.0.0/0" : var.admin_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# El puerto 9100 (Node Exporter) NO se abre a Internet: solo la instancia de
# monitoreo puede hacerle scraping. /metrics no tiene autenticacion y revela
# detalle del servidor, asi que el origen se acota al Security Group vecino.
resource "aws_vpc_security_group_ingress_rule" "app_node_exporter" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "Node Exporter, solo desde la instancia de monitoreo"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
}

# Exporters de nginx y de PostgreSQL, tambien solo desde monitoreo.
# Se declara una regla por puerto en vez de un rango 9113-9187: un rango abriria
# 73 puertos adicionales que nadie usa. La regla minima necesaria, y nada mas.
resource "aws_vpc_security_group_ingress_rule" "app_nginx_exporter" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "Exporter de nginx, solo desde la instancia de monitoreo"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  from_port                    = 9113
  to_port                      = 9113
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_postgres_exporter" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "Exporter de PostgreSQL, solo desde la instancia de monitoreo"
  referenced_security_group_id = aws_security_group.monitoring[0].id
  from_port                    = 9187
  to_port                      = 9187
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Salida a Internet para descargar imagenes de contenedor y paquetes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Instancia de monitoreo (Prometheus + Grafana) --------------------------
resource "aws_security_group" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name        = "${var.project_name}-monitoring-sg"
  description = "Stack de monitoreo: UI de Grafana y Prometheus para administracion"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-monitoring-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_ssh" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_grafana" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  description       = "UI de Grafana"
  cidr_ipv4         = var.admin_cidr
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_prometheus" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  description       = "UI y API de Prometheus"
  cidr_ipv4         = var.admin_cidr
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_all" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  description       = "Salida a Internet y scraping de la instancia de aplicacion"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- RDS (opcional) ---------------------------------------------------------
resource "aws_security_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name        = "${var.project_name}-rds-sg"
  description = "Base de datos central: acceso solo desde la aplicacion"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  count = var.enable_rds ? 1 : 0

  security_group_id            = aws_security_group.rds[0].id
  description                  = "PostgreSQL, solo desde la instancia de aplicacion"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
