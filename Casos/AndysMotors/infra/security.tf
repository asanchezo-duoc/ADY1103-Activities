# ---------------------------------------------------------------------------
# Security Groups
#
# Tres grupos, uno por rol. Se referencian entre si por ID y no por IP, para que
# las reglas sigan siendo validas aunque las instancias cambien de direccion.
#
# La idea de fondo: solo el balanceador recibe trafico de personas. Las
# plataformas internas y la base de datos no son alcanzables desde Internet;
# solo aceptan conexiones de quien tiene que hablarles.
# ---------------------------------------------------------------------------

# --- ServerBorde: la unica puerta de entrada --------------------------------
resource "aws_security_group" "borde" {
  name        = "${var.project_name}-borde-sg"
  description = "Balanceador HAProxy: entrada publica de la plataforma"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-borde-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "borde_http" {
  security_group_id = aws_security_group.borde.id
  description       = var.allow_public_web ? "Sitio publico, abierto a Internet" : "Sitio publico, solo administracion"
  cidr_ipv4         = var.allow_public_web ? "0.0.0.0/0" : var.admin_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "borde_metricas" {
  security_group_id = aws_security_group.borde.id
  description       = "Metricas y pagina de estado de HAProxy"
  cidr_ipv4         = var.admin_cidr
  from_port         = 8404
  to_port           = 8404
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "borde_metricas_monitoreo" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id            = aws_security_group.borde.id
  description                  = "Scraping de las metricas de HAProxy desde el stack de monitoreo"
  referenced_security_group_id = aws_security_group.monitoreo[0].id
  from_port                    = 8404
  to_port                      = 8404
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "borde_ssh" {
  security_group_id = aws_security_group.borde.id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "borde_salida" {
  security_group_id = aws_security_group.borde.id
  description       = "Salida a Internet y hacia las plataformas internas"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Plataformas de aplicacion ----------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Plataformas de negocio: solo reciben trafico del balanceador y del monitoreo"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-app-sg" }
}

# Una regla por plataforma, y no un rango 8081-8086: un rango abriria puertos
# que nadie usa. Se abre exactamente lo necesario.
resource "aws_vpc_security_group_ingress_rule" "app_desde_borde" {
  for_each = local.puertos

  security_group_id            = aws_security_group.app.id
  description                  = "Trafico de ${each.key} desde el balanceador"
  referenced_security_group_id = aws_security_group.borde.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

# El stack de monitoreo necesita alcanzar /metrics de cada plataforma. Es el
# mismo puerto del trafico normal, porque las aplicaciones exponen sus metricas
# en el propio servicio.
resource "aws_vpc_security_group_ingress_rule" "app_desde_monitoreo" {
  for_each = var.enable_monitoring ? local.puertos : {}

  security_group_id            = aws_security_group.app.id
  description                  = "Scraping de /metrics de ${each.key} desde el monitoreo"
  referenced_security_group_id = aws_security_group.monitoreo[0].id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

# Las plataformas se llaman entre si: el sitio web consulta stock, agenda y CRM.
# En la topologia compacta esto ocurre dentro de la misma maquina, pero la regla
# no molesta.
resource "aws_vpc_security_group_ingress_rule" "app_entre_si" {
  for_each = local.puertos

  security_group_id            = aws_security_group.app.id
  description                  = "Llamadas a ${each.key} desde otras plataformas"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_salida" {
  security_group_id = aws_security_group.app.id
  description       = "Salida a Internet para descargar imagenes y paquetes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Base de datos ----------------------------------------------------------
# Sirve tanto para el contenedor PostgreSQL de ServerData como para RDS.
resource "aws_security_group" "datos" {
  name        = "${var.project_name}-datos-sg"
  description = "Base de datos central: solo accesible desde las plataformas de aplicacion"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-datos-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "datos_desde_app" {
  security_group_id            = aws_security_group.datos.id
  description                  = "PostgreSQL, solo desde las plataformas de aplicacion"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "datos_ssh" {
  security_group_id = aws_security_group.datos.id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "datos_salida" {
  security_group_id = aws_security_group.datos.id
  description       = "Salida a Internet para descargar imagenes"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Stack de monitoreo de referencia ---------------------------------------
resource "aws_security_group" "monitoreo" {
  count = var.enable_monitoring ? 1 : 0

  name        = "${var.project_name}-monitoreo-sg"
  description = "Prometheus y Grafana de referencia"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-monitoreo-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoreo_grafana" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoreo[0].id
  description       = "UI de Grafana"
  cidr_ipv4         = var.admin_cidr
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "monitoreo_prometheus" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoreo[0].id
  description       = "UI y API de Prometheus"
  cidr_ipv4         = var.admin_cidr
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "monitoreo_ssh" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoreo[0].id
  description       = "SSH de administracion"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "monitoreo_salida" {
  count = var.enable_monitoring ? 1 : 0

  security_group_id = aws_security_group.monitoreo[0].id
  description       = "Salida a Internet y scraping de las plataformas"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
