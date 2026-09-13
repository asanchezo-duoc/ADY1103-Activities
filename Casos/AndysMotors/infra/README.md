# Infraestructura de Andys Motors en AWS Academy

Terraform + Docker para levantar la arquitectura del [caso Andys Motors](../README.md)
sobre una cuenta de **AWS Academy Learner Lab**.

> Este proyecto está escrito específicamente para las restricciones del Learner Lab. Varias
> decisiones que aquí parecen raras (no crear roles de IAM, usar la VPC por defecto, dejar
> RDS apagado) son consecuencia directa de esas restricciones, y están explicadas en la
> sección 3.

## Índice

1. [Qué levanta](#1-qué-levanta)
2. [Requisitos](#2-requisitos)
3. [Limitantes del Learner Lab](#3-limitantes-del-learner-lab)
4. [Credenciales](#4-credenciales)
5. [Uso](#5-uso)
6. [Después del apply](#6-después-del-apply)
7. [Cuando se reinicia la sesión del lab](#7-cuando-se-reinicia-la-sesión-del-lab)
8. [Encender RDS](#8-encender-rds)
9. [Verificar qué permite tu lab](#9-verificar-qué-permite-tu-lab)
10. [Presupuesto](#10-presupuesto)
11. [Troubleshooting](#11-troubleshooting)
12. [Destruir el laboratorio](#12-destruir-el-laboratorio)
13. [Qué NO hace este proyecto](#13-qué-no-hace-este-proyecto)

---

## 1) Qué levanta

El caso describe seis plataformas. **No necesitan seis servidores**: corren como
contenedores sobre una sola instancia, lo que mantiene el laboratorio dentro del
presupuesto y del límite de instancias del lab.

| Elemento del caso | Cómo se implementa |
|---|---|
| Sitio web público, CRM, sistema de pagos | Contenedor `nginx` en la instancia de aplicación |
| Base de datos central | Contenedor `postgres` (o Amazon RDS real, ver sección 8) |
| Archivos, imágenes, respaldos, reportes | Bucket **Amazon S3** con versionado y cifrado |
| Aplicación sobre EC2 | Instancia **EC2** `t3.micro` con Amazon Linux 2023 |
| DNS público (Route 53 en el diagrama) | `sslip.io` — ver sección 13 |
| Monitoreo | Segunda instancia EC2 con **Prometheus + Grafana** |

Además, la instancia de aplicación expone **tres exporters**, que es el puente directo con
[EA2/Act2-3](../../../EA2/Act2-3):

| Puerto | Exporter | Qué traduce |
|---|---|---|
| 9100 | `node-exporter` | Sistema operativo del host: CPU, memoria, disco, red |
| 9113 | `nginx-prometheus-exporter` | Conexiones y peticiones del sitio web, CRM y pagos |
| 9187 | `postgres-exporter` | Estado de la base de datos central |

Prometheus hace **pull** de los tres. Al terminar, `/targets` debe mostrar los jobs `node`,
`nginx` y `postgres` en verde.

## 2) Requisitos

- Una sesión activa de **AWS Academy Learner Lab**.
- **Docker** en tu máquina (Terraform corre dentro de un contenedor, no hace falta
  instalarlo). Si prefieres usar un Terraform ya instalado, exporta `TF_LOCAL=1`.
- La llave `labsuser.pem`, que se descarga desde el panel **AWS Details** del lab, para
  entrar por SSH.

## 3) Limitantes del Learner Lab

Estas son las que determinan el diseño. Las primeras cuatro son restricciones duras y
conocidas; las de la sección 9 varían entre versiones del lab y hay que verificarlas.

### 3.1 No se pueden crear recursos de IAM

El lab deniega por política `iam:CreateRole`, `iam:CreateUser` y `iam:CreatePolicy`. Este
proyecto **no crea ningún recurso de IAM**: consume el perfil de instancia que el lab ya
trae.

```hcl
data "aws_iam_instance_profile" "lab" {
  name = "LabInstanceProfile"
}

resource "aws_instance" "app" {
  iam_instance_profile = data.aws_iam_instance_profile.lab.name
  # ...
}
```

**Consecuencia práctica**: casi ningún módulo del Terraform Registry funciona en el Learner
Lab, porque prácticamente todos crean roles por dentro. Por eso aquí los recursos están
escritos uno a uno.

### 3.2 Las credenciales expiran

Son credenciales temporales (STS) con `aws_session_token`, y mueren al cerrar la sesión del
lab. Un `apply` largo puede fallar a mitad de camino con `ExpiredToken`, dejando recursos
creados que el state no registró.

**Mitigación**: RDS está apagado por defecto, que es el recurso lento (10-15 minutos). Sin
RDS, un `apply` completo toma alrededor de un minuto y entra holgado en cualquier ventana de
credenciales.

### 3.3 Al cerrar la sesión, las instancias se detienen

No se destruyen: quedan detenidas y se pueden volver a encender. Pero al encenderlas
**cambia la IP pública**. Ver la sección 7 para qué se rompe y cómo recuperarlo.

### 3.4 Región e instancias acotadas

El lab normalmente solo habilita **us-east-1**, y restringe los tipos de instancia a
familias pequeñas (`t2`/`t3`). Los valores por defecto de este proyecto ya respetan eso.

## 4) Credenciales

En el lab, botón **AWS Details** → **AWS CLI**. Copia el bloque completo a un archivo
`.aws-credentials` dentro de esta carpeta:

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

`.aws-credentials` está en `.gitignore`. **Nunca escribas las llaves en un archivo `.tf`**:
quedarían en el repositorio para siempre.

Cada vez que reinicies el lab, ese bloque cambia y hay que volver a copiarlo.

## 5) Uso

```bash
cd Casos/AndysMotors/infra

# 1. Variables: copiar la plantilla y completar
cp terraform.tfvars.example terraform.tfvars
curl -s ifconfig.me          # tu IP pública, para admin_cidr
# editar terraform.tfvars: admin_cidr, db_password, grafana_admin_password

# 2. Inicializar (descarga el proveedor de AWS)
./scripts/tf.sh init

# 3. Ver qué se va a crear, SIN crear nada
./scripts/tf.sh plan

# 4. Crear la infraestructura
./scripts/tf.sh apply

# 5. Ver las URLs y comandos resultantes
./scripts/tf.sh output
```

`tf.sh` lee `.aws-credentials`, exporta las variables de entorno que Terraform espera y lo
ejecuta dentro de un contenedor `hashicorp/terraform`. Acepta cualquier subcomando de
Terraform.

> **Costumbre que conviene tomar**: correr siempre `plan` antes de `apply` y leer el
> resumen. En un entorno con presupuesto limitado, `plan` es lo que evita descubrir que
> creaste algo caro después de haberlo creado.

## 6) Después del apply

El `user_data` demora entre **2 y 4 minutos** en terminar después de que la instancia
aparece como `running`. Si el sitio no responde de inmediato, es normal.

```bash
# Ver el avance del arranque
ssh -i labsuser.pem ec2-user@<IP_APP>
sudo tail -f /var/log/cloud-init-output.log

# Contenedores de la aplicación
cd /opt/andys && sudo docker compose ps

# Los tres exporters respondiendo
curl -s localhost:9100/metrics | head    # sistema operativo
curl -s localhost:9113/metrics | head    # nginx
curl -s localhost:9187/metrics | head    # postgresql
```

Checklist de que quedó bien:

- [ ] `http://<IP_APP>` muestra el sitio de Andys Motors, con enlaces a CRM y pagos.
- [ ] `http://<IP_APP>/health` devuelve JSON con `"status":"ok"`.
- [ ] `http://<IP_MONITOREO>:9090/targets` muestra `node`, `nginx` y `postgres` en **UP**.
- [ ] Grafana en `http://<IP_MONITOREO>:3000` entra con `admin` y tu password, y el
      datasource **Prometheus** ya existe sin configurarlo.
- [ ] El bucket S3 aparece en la consola con el nombre que entregó `terraform output`.

## 7) Cuando se reinicia la sesión del lab

Esto es lo que pasa en la práctica, y conviene saberlo antes de que ocurra en clase:

| Qué | Qué le pasa |
|---|---|
| Instancias EC2 | Quedan **detenidas**. Hay que encenderlas desde la consola o con `aws ec2 start-instances`. |
| IP **pública** | **Cambia**. Las URLs anteriores dejan de servir. |
| IP **privada** | Se conserva. |
| Bucket S3 y sus objetos | Se conservan. |
| State de Terraform | Se conserva (local o en S3). |
| Credenciales | Expiran: hay que copiarlas de nuevo (sección 4). |

La buena noticia es que **Prometheus sigue funcionando sin tocar nada**: su configuración
apunta a la IP *privada* de la instancia de aplicación, que no cambia. Ese fue el motivo de
usar la privada y no la pública.

Lo que sí hay que recuperar son las URLs, y para eso basta:

```bash
./scripts/tf.sh refresh     # actualiza el state con las IP nuevas
./scripts/tf.sh output      # muestra las URLs actualizadas
```

## 8) Encender RDS

Por defecto la base de datos del caso corre como contenedor PostgreSQL. Para levantar un
Amazon RDS real:

```hcl
# terraform.tfvars
enable_rds = true
```

```bash
./scripts/tf.sh apply
```

Antes de hacerlo, ten presente:

- **Tarda entre 10 y 15 minutos.** Es justo donde suelen expirar las credenciales. Copia
  credenciales frescas inmediatamente antes.
- **La instancia de aplicación se recrea**, porque necesita el endpoint de RDS para
  configurarse. Terraform esperará a que la base esté lista antes de levantarla.
- **Es lo que más presupuesto consume** de todo el proyecto.

El ejercicio que justifica encenderlo: comparar, en CloudWatch, qué métricas entrega RDS
(`CPUUtilization`, `DatabaseConnections`, `FreeStorageSpace`) contra lo que entrega el
`postgres-exporter` del contenedor. Es una demostración concreta de qué se gana y qué se
pierde con un servicio administrado.

## 9) Verificar qué permite tu lab

Estos servicios **varían entre versiones del Learner Lab** y conviene comprobarlos antes de
planificar una clase alrededor de ellos. Ninguno es necesario para este proyecto, pero
saberlo sirve para extenderlo:

| Servicio | Para qué serviría | Cómo comprobarlo |
|---|---|---|
| Route 53 | Nombres DNS reales en vez de `sslip.io` | `aws route53 list-hosted-zones` |
| ELB / ALB | Balanceador delante de la aplicación | `aws elbv2 describe-load-balancers` |
| DynamoDB | Bloqueo del state de Terraform | `aws dynamodb list-tables` |
| Elastic IP | IP pública que no cambie al reiniciar | `aws ec2 describe-addresses` |
| Secrets Manager | Guardar los passwords fuera de `tfvars` | `aws secretsmanager list-secrets` |

Si el comando responde (aunque sea con una lista vacía), el servicio está habilitado para
lectura. Si devuelve `AccessDenied` o `UnauthorizedOperation`, está bloqueado por política y
no hay forma de habilitarlo desde la cuenta del lab.

## 10) Presupuesto

Con los valores por defecto (dos `t3.micro`, dos discos gp3 de 20 GB y un bucket S3 casi
vacío), el gasto es de unos pocos centavos de dólar por hora de laboratorio.

Lo que de verdad quema presupuesto:

1. **Dejar los recursos corriendo entre clases.** Por eso `terraform destroy` al terminar.
2. **RDS encendido**, sobre todo si queda corriendo varios días.
3. **NAT Gateway**, que este proyecto evita por completo al usar la VPC por defecto con
   subredes públicas.

## 11) Troubleshooting

| Error | Causa | Solución |
|---|---|---|
| `ExpiredToken` o `InvalidClientTokenId` | Las credenciales del lab expiraron | Copiar de nuevo el bloque de **AWS Details** a `.aws-credentials` y reintentar |
| `UnauthorizedOperation` / `AccessDenied` al crear algo | El lab bloquea esa acción por política | No se puede habilitar desde la cuenta. Ver sección 9 y buscar una alternativa |
| `You are not authorized to perform: iam:CreateRole` | Algo intentó crear un rol | Este proyecto no lo hace. Si agregaste un módulo del registry, esa es la causa (sección 3.1) |
| `InvalidKeyPair.NotFound` | No existe el par de llaves `vockey` | Descargarlo desde **AWS Details**, o ajustar `key_name` al nombre real |
| `VcpuLimitExceeded` | Se alcanzó el límite de instancias del lab | Apagar instancias de laboratorios anteriores, o `enable_monitoring = false` |
| El sitio no responde tras el `apply` | El `user_data` todavía está corriendo | Esperar 2-4 minutos; revisar `/var/log/cloud-init-output.log` |
| Los targets salen **DOWN** en Prometheus | Los contenedores de la aplicación aún no arrancan, o el Security Group | Revisar `docker compose ps` en la instancia de aplicación |
| `terraform destroy` se queda pegado en el bucket S3 | El bucket tiene objetos y versiones | Ya está resuelto con `force_destroy = true`; si falla igual, vaciarlo desde la consola |
| La creación de RDS falla por cifrado | El lab restringe KMS | Poner `storage_encrypted = false` en `database.tf` y reintentar |
| Perdiste `terraform.tfstate` | Quedaron recursos huérfanos | Borrarlos a mano desde la consola. Para que no vuelva a pasar, usar `backend.tf.example` |

## 12) Destruir el laboratorio

**Al final de cada clase, siempre:**

```bash
./scripts/tf.sh destroy
```

Y después confirma en la consola de AWS que no quedó nada: EC2, RDS, volúmenes EBS
sueltos y buckets S3. Un volumen EBS huérfano sigue costando aunque su instancia ya no
exista.

## 13) Qué NO hace este proyecto

Decisiones tomadas a propósito, con su motivo:

| No se usa | Por qué | Qué se usa en cambio |
|---|---|---|
| **Route 53** | Una hosted zone tiene costo mensual fijo y no siempre está habilitada. Para el caso no aporta nada pedagógico | `sslip.io`, que resuelve la IP contenida en el propio nombre, gratis y sin permisos |
| **VPC propia** | Más permisos involucrados, más lento, más que destruir, y lleva a la tentación del NAT Gateway | La VPC por defecto de la cuenta |
| **ALB / Auto Scaling** | Costo y complejidad que no aportan al objetivo de observabilidad | Una instancia con contenedores |
| **Roles de IAM propios** | El lab lo prohíbe (sección 3.1) | `LabInstanceProfile` |
| **Bloqueo del state con DynamoDB** | Cada alumno trabaja en su propia cuenta | State local, o S3 si se usa `backend.tf.example` |
| **Secrets Manager** | Tiene costo y no siempre está habilitado | `terraform.tfvars` fuera de git, o variables `TF_VAR_*` |

Si tu lab sí habilita Route 53 o ALB, agregarlos es un buen ejercicio de extensión.
