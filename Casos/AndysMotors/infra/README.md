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

Despliega el [entorno de demostración](../demo) completo: las seis plataformas del caso
como aplicaciones reales instrumentadas, la base de datos central, y un balanceador HAProxy
como única puerta de entrada.

### Topología

La variable `topologia` decide cómo se reparten las plataformas. El entorno desplegado es
**idéntico** en ambos casos: cambia solo qué perfiles de Docker Compose levanta cada
máquina.

| `topologia` | Servidores | Cuándo usarla |
|---|---|---|
| `"completa"` (por defecto) | 7: uno por plataforma más el balanceador | Es el despliegue que describe el caso. Permite scraping multi-host real y reglas de Security Group entre servidores |
| `"compacta"` | 2: todas las plataformas en uno, más el balanceador | Cuando la cuota de instancias del laboratorio no alcanza |

Con `enable_monitoring = true` se suma una instancia más con Prometheus y Grafana de
referencia.

| Servidor | Plataforma del caso | Puerto |
|---|---|---|
| `borde` | Balanceador HAProxy: entrada pública | 80, 8404 |
| `web` | Sitio web público | 8081 |
| `stock` | Consulta de stock de vehículos | 8082 |
| `agenda` | Agendamiento de visitas | 8083 |
| `crm` | CRM y sistema de ventas | 8084 |
| `pagos` | Sistema de pagos y proveedor externo | 8085, 8086 |
| `data` | Base de datos central | 5432 |

Más un bucket **S3** para los documentos del negocio, que además transporta el código del
entorno hasta las instancias.

### Dos decisiones que conviene entender

**Las IP privadas se fijan por adelantado.** Cada servidor necesita las direcciones de los
demás dentro de su script de arranque. Si dejáramos que AWS las asignara, Terraform tendría
que leer la IP de una instancia para construir otra del mismo recurso: una referencia
circular imposible de resolver. Se calculan con `cidrhost()` sobre el rango de la subred,
desde el `.200` hacia arriba. Como efecto secundario, no cambian nunca.

**El código viaja por S3.** Terraform empaqueta la carpeta `demo/` y la sube al bucket; cada
instancia la descarga al arrancar con el perfil del laboratorio. Se descartó clonar el
repositorio (obligaría a que fuera público) e incrustar el código en el `user_data` (AWS lo
limita a 16 KB).

### Lo que NO incluye

El entorno **expone** telemetría, no la recolecta. No hay Node Exporter, ni
postgres-exporter, ni Prometheus, ni Grafana (salvo el stack de referencia opcional).
Construir todo eso es el trabajo del estudiante.

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

### 3.5 La cuota de instancias es el límite real, no el presupuesto

Con `topologia = "completa"` y el monitoreo de referencia encendido son **8 instancias**. En
dinero eso es despreciable (unos centavos de dólar por hora), pero puede chocar con el
límite de instancias o de vCPU de tu versión del lab.

Si el `apply` falla con `VcpuLimitExceeded` o `InstanceLimitExceeded`, hay dos salidas que no
cambian nada del entorno desplegado:

```hcl
topologia         = "compacta"   # 2 instancias en vez de 7
enable_monitoring = false        # una menos
```

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

El arranque de cada servidor toma entre **3 y 6 minutos**: instala Docker, descarga el
entorno desde S3 y, en los servidores de aplicación, construye la imagen. Que la instancia
diga `running` no significa que ya esté lista.

```bash
# Avance del arranque, en cualquier servidor
ssh -i labsuser.pem ec2-user@<IP_PUBLICA>
sudo tail -f /var/log/cloud-init-output.log

# Contenedores levantados en esa máquina
cd /opt/andys && sudo docker compose ps
```

Checklist de que quedó bien:

- [ ] `http://<IP_BORDE>/` responde con la portada de Andys Motors.
- [ ] `http://<IP_BORDE>/stock/api/stock` devuelve el catálogo de vehículos.
- [ ] `http://<IP_BORDE>:8404/stats` muestra **todas las plataformas en verde**.
- [ ] `http://<IP_BORDE>:8404/metrics` devuelve más de 200 familias de métricas.
- [ ] `terraform output endpoints_de_metricas` lista las direcciones a scrapear.
- [ ] Un flujo de negocio completo funciona:
      ```bash
      curl -X POST http://<IP_BORDE>/api/contacto -H 'Content-Type: application/json' \
        -d '{"nombre":"Prueba","monto_clp":15000000}'
      ```
- [ ] (Si `enable_monitoring = true`) Prometheus muestra los jobs en **UP** y Grafana entra.

Para generar tráfico con la curva horaria del negocio y para encender los escenarios de
falla, ver el [README del entorno](../demo/README.md).

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

La buena noticia es que **la plataforma sigue funcionando sin tocar nada**: HAProxy apunta a
las IP *privadas* de los backends, y esas están fijadas por Terraform, así que no cambian ni
al reiniciar ni al recrear. Lo mismo vale para el Prometheus de referencia.

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

Con los valores por defecto (`topologia = "completa"` más el monitoreo de referencia: ocho
`t3.micro`, ocho discos gp3 de 20 GB y un bucket S3 casi vacío), el gasto es de unos pocos
centavos de dólar por hora de laboratorio. Con `topologia = "compacta"` baja a tres
instancias.

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
| `VcpuLimitExceeded` / `InstanceLimitExceeded` | La topología completa pide 7 u 8 instancias | `topologia = "compacta"` y/o `enable_monitoring = false` (ver 3.5) |
| `InvalidIPAddress.InUse` al crear una instancia | Alguna de las IP privadas fijas (`.200` en adelante) ya está ocupada en la subred | Subir `ip_base` en `locals.tf` a un valor libre, por ejemplo 210 |
| Un backend sale DOWN en `:8404/stats` | Ese servidor aún está arrancando, o su contenedor falló | Esperar a que termine el `user_data`; si persiste, `sudo docker compose logs` en esa máquina |
| Todo devuelve 503 desde el balanceador | Los backends todavía no pasan el health check | HAProxy los reincorpora solo, sin reiniciar nada |
| El `user_data` falla en `aws s3 cp` | El perfil de instancia no tiene acceso al bucket, o la región es otra | Verificar que la instancia use `LabInstanceProfile` y que `aws_region` sea la del bucket |
| El `apply` sube miles de archivos al bucket | Se corrió `npm install` dentro de `demo/app` | Borrar `demo/app/node_modules`. El código ya lo excluye, pero conviene no generarlo |

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
| **ALB / Auto Scaling** | Costo, y el balanceador de AWS no expone métricas Prometheus | **HAProxy**, que trae el exporter integrado y es un objeto de estudio en sí mismo |
| **Roles de IAM propios** | El lab lo prohíbe (sección 3.1) | `LabInstanceProfile` |
| **Bloqueo del state con DynamoDB** | Cada alumno trabaja en su propia cuenta | State local, o S3 si se usa `backend.tf.example` |
| **Secrets Manager** | Tiene costo y no siempre está habilitado | `terraform.tfvars` fuera de git, o variables `TF_VAR_*` |

Si tu lab sí habilita Route 53 o ALB, agregarlos es un buen ejercicio de extensión.
