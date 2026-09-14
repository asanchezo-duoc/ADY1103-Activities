# ---------------------------------------------------------------------------
# Entorno
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Region de AWS. El Learner Lab normalmente solo habilita us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para el nombre de todos los recursos."
  type        = string
  default     = "andys-motors"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "Usar solo minusculas, numeros y guiones (3 a 24 caracteres)."
  }
}

variable "key_name" {
  description = <<-EOT
    Nombre del par de llaves EC2 para acceder por SSH. El Learner Lab ya trae una
    llamada "vockey" (se descarga desde el panel AWS Details). No se crea aqui
    porque el lab no permite gestionar llaves de forma consistente.
  EOT
  type        = string
  default     = "vockey"
}

variable "admin_cidr" {
  description = <<-EOT
    Rango de IP desde el que se administrara el laboratorio (SSH, Grafana,
    Prometheus). Obtener la IP publica propia con:  curl -s ifconfig.me
    y escribirla como /32, por ejemplo "200.83.12.45/32".
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr debe ser un CIDR valido, por ejemplo 200.83.12.45/32."
  }
}

variable "allow_public_web" {
  description = <<-EOT
    Si es true, el puerto 80 del balanceador queda abierto a Internet
    (0.0.0.0/0), que es el comportamiento real de un sitio publico. Si es false
    (recomendado para el laboratorio), solo se abre hacia admin_cidr.
  EOT
  type        = bool
  default     = false
}

variable "topologia" {
  description = <<-EOT
    Como se reparten las plataformas del caso entre servidores.

      "completa"  una maquina por plataforma, como describe el caso. Son seis
                  servidores mas el balanceador (siete, u ocho con el stack de
                  monitoreo de referencia).

      "compacta"  todas las plataformas en una maquina, mas el balanceador.
                  Mismo entorno y mismos perfiles de Compose; sirve cuando la
                  cuota de instancias del laboratorio no alcanza.

    El codigo desplegado es identico en ambos casos: cambia solo que perfiles
    levanta cada maquina.
  EOT
  type        = string
  default     = "completa"

  validation {
    condition     = contains(["completa", "compacta"], var.topologia)
    error_message = "topologia debe ser \"completa\" o \"compacta\"."
  }
}

variable "admin_token" {
  description = <<-EOT
    Token que protege el panel de inyeccion de fallas (/admin/fallas) de cada
    plataforma. Sin el, cualquiera que alcance el puerto podria romper el
    entorno.
  EOT
  type        = string
  sensitive   = true
  default     = "andys-lab"
}

# ---------------------------------------------------------------------------
# Computo
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "Tipo de instancia EC2. El Learner Lab restringe a familias t2/t3 pequenias."
  type        = string
  default     = "t3.micro"
}

variable "enable_monitoring" {
  description = <<-EOT
    Levanta una instancia adicional con Prometheus + Grafana ya configurados,
    como referencia.

    IMPORTANTE: si el ejercicio es que el estudiante construya su propio stack
    de monitoreo, hay que ponerlo en **false**. El entorno de Andys Motors solo
    expone telemetria; recolectarla y visualizarla es justamente el trabajo.
  EOT
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Tamanio del disco raiz en GB."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

variable "enable_rds" {
  description = <<-EOT
    Crea una instancia Amazon RDS PostgreSQL real.

    APAGADO POR DEFECTO a proposito: RDS tarda entre 10 y 15 minutos en crearse,
    que es justo donde suelen expirar las credenciales temporales del lab, y es
    el recurso que mas presupuesto consume. Con enable_rds = false la base de
    datos del caso corre como contenedor PostgreSQL en la instancia de la
    aplicacion, que alcanza para todo el laboratorio.

    Encenderlo una sesion es un ejercicio valioso: permite comparar las metricas
    que CloudWatch entrega de RDS contra las que entrega un contenedor.
  EOT
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "Clase de instancia RDS. El Learner Lab restringe a clases pequenias."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos inicial."
  type        = string
  default     = "andysmotors"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos."
  type        = string
  default     = "andysadmin"
}

variable "db_password" {
  description = <<-EOT
    Password del usuario administrador. Se usa tanto para RDS como para el
    contenedor PostgreSQL. Definirlo en terraform.tfvars (que NO se versiona) o
    exportarlo como TF_VAR_db_password.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]{12,41}$", var.db_password))
    error_message = <<-EOT
      El password debe tener entre 12 y 41 caracteres y usar solo letras, numeros,
      guion bajo, punto, guion o virgulilla. El juego de caracteres es acotado a
      proposito: RDS rechaza '/', '"', '@' y espacios, y esos mismos caracteres
      romperian la cadena de conexion del exporter de PostgreSQL.
    EOT
  }
}

variable "grafana_admin_password" {
  description = <<-EOT
    Password del usuario admin de Grafana. Definirlo en terraform.tfvars (que NO
    se versiona) o exportarlo como TF_VAR_grafana_admin_password.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]{12,}$", var.grafana_admin_password))
    error_message = "Minimo 12 caracteres, usando solo letras, numeros, guion bajo, punto, guion o virgulilla."
  }
}
