# EA3 - Act 3.1: Aprovisionar la infraestructura de Andys Motors con Terraform y Docker

Guia paso a paso para levantar, con **infraestructura como codigo**, la plataforma completa
de la empresa del caso sobre una cuenta de **AWS Academy Learner Lab**: instancias EC2,
almacenamiento S3, Security Groups y los servicios de la empresa corriendo en contenedores.

Al terminar tendras un entorno AWS real, reproducible y desechable, que es la base sobre la
que se trabajan las actividades de monitoreo en la nube de esta unidad.

> **Contexto del negocio**: [`Casos/AndysMotors`](../../Casos/AndysMotors).
> Lee el caso antes de empezar: vas a desplegar exactamente esa arquitectura.

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Que vas a construir](#2-que-vas-a-construir)
3. [Requisitos previos](#3-requisitos-previos)
4. [Antes de tocar nada: cuatro ideas](#4-antes-de-tocar-nada-cuatro-ideas)
5. [Paso 1 - Credenciales del laboratorio](#5-paso-1---credenciales-del-laboratorio)
6. [Paso 2 - Configurar tus variables](#6-paso-2---configurar-tus-variables)
7. [Paso 3 - init y plan: mirar antes de crear](#7-paso-3---init-y-plan-mirar-antes-de-crear)
8. [Paso 4 - apply: crear la infraestructura](#8-paso-4---apply-crear-la-infraestructura)
9. [Paso 5 - Verificar la plataforma](#9-paso-5---verificar-la-plataforma)
10. [Paso 6 - Reconocer la telemetria disponible](#10-paso-6---reconocer-la-telemetria-disponible)
11. [Paso 7 - La misma maquina, dos miradas](#11-paso-7---la-misma-maquina-dos-miradas)
12. [Paso 8 - Leer el codigo](#12-paso-8---leer-el-codigo)
13. [Paso 9 - Modificar la infraestructura](#13-paso-9---modificar-la-infraestructura)
14. [Paso 10 (opcional) - Encender RDS](#14-paso-10-opcional---encender-rds)
15. [Paso 11 - Destruir](#15-paso-11---destruir)
16. [Evidencias esperadas](#16-evidencias-esperadas)
17. [Troubleshooting](#17-troubleshooting)
18. [Checklist de verificacion](#18-checklist-de-verificacion)

---

## 1) Objetivo de la actividad

Que seas capaz de:

- Explicar que es **infraestructura como codigo** y en que se diferencia de crear recursos a
  mano en la consola.
- Ejecutar el ciclo completo de Terraform: `init`, `plan`, `apply`, `destroy`.
- Leer un `plan` **antes** de aplicarlo y entender que va a pasar.
- Explicar que es el **state** y por que perderlo es un problema.
- Desplegar una plataforma completa en AWS combinando Terraform (la infraestructura) con
  Docker (los servicios que corren sobre ella).
- Reconocer las **restricciones de un entorno acotado** como el Learner Lab, y como el
  codigo se adapta a ellas.
- Contrastar la telemetria que entrega el proveedor de nube con la que entrega tu propio
  stack de observabilidad sobre la misma maquina.

## 2) Que vas a construir

El caso describe seis plataformas. Vas a desplegarlas como **aplicaciones reales**, cada una
en su propio servidor, detras de un balanceador que es la unica puerta de entrada.

```
                             +---------------------+
        Internet  --- 80 --> |    ServerBorde      |
                             |  HAProxy            |
                             |  :8404/metrics      |
                             +---------------------+
                                       |
            +--------------+-----------+-----------+--------------+
            v              v           v           v              v
     +-----------+  +-----------+ +-----------+ +-----------+ +-----------+
     | ServerWeb |  |ServerStock| |ServerAgen.| | ServerCRM | |ServerPagos|
     |   :8081   |  |   :8082   | |   :8083   | |   :8084   | |   :8085   |
     +-----------+  +-----------+ +-----------+ +-----------+ +-----------+
                            |           |           |             |
                            +-----------+-----+-----+-------------+
                                              v
                                     +-----------------+
                                     |   ServerData    |
                                     |  PostgreSQL     |
                                     +-----------------+
```

Cada plataforma expone `/metrics` en su propio puerto, y HAProxy expone las suyas en el
8404. **No hay Prometheus ni Grafana desplegados por defecto**: el entorno entrega
telemetria, recolectarla es otro trabajo.

| Recurso | Servicio AWS | Para que |
|---|---|---|
| 6 servidores de plataforma | EC2 `t3.micro` | Sitio web, stock, agenda, CRM, pagos y base de datos |
| Balanceador | EC2 `t3.micro` | HAProxy: entrada publica y metricas del borde |
| Bucket de documentos | S3 | Archivos del negocio, y transporte del codigo a las instancias |
| Reglas de acceso | Security Groups | Quien puede hablar con quien |
| Base de datos (opcional) | RDS PostgreSQL | Paso 10 |

> **Si la cuota de instancias de tu laboratorio no alcanza**, pon `topologia = "compacta"` en
> `terraform.tfvars`: son 2 servidores en vez de 7, con el mismo entorno desplegado. La
> seccion 3.5 del [README de `infra/`](../../Casos/AndysMotors/infra/README.md) lo explica.

## 3) Requisitos previos

- Sesion activa de **AWS Academy Learner Lab**.
- **Docker** instalado en tu maquina. Terraform corre dentro de un contenedor, asi que no
  necesitas instalarlo. (Si ya lo tienes instalado y prefieres usarlo, exporta `TF_LOCAL=1`.)
- La llave **`labsuser.pem`**, que se descarga del panel **AWS Details** del lab, para poder
  entrar por SSH.
- Haber completado [EA2/Act2-1](../../EA2/Act2-1) y [EA2/Act2-3](../../EA2/Act2-3): vas a
  reconocer Prometheus, Grafana y los exporters, porque son los mismos.

Todo el codigo esta en [`Casos/AndysMotors/infra`](../../Casos/AndysMotors/infra). Trabajaras
siempre desde ahi:

```bash
cd Casos/AndysMotors/infra
```

## 4) Antes de tocar nada: cuatro ideas

### 4.1 Declarativo, no imperativo

En la consola de AWS das **ordenes**: crea esta instancia, abre este puerto. Con Terraform
**describes el resultado** que quieres, y el se encarga de averiguar que hay que hacer para
llegar ahi.

La consecuencia mas util: si aplicas dos veces seguidas la misma configuracion, la segunda
vez **no pasa nada**, porque la realidad ya coincide con lo declarado. Eso se llama
idempotencia, y lo vas a comprobar en el Paso 9.

### 4.2 El ciclo de trabajo

| Comando | Que hace | Cuando |
|---|---|---|
| `init` | Descarga el proveedor de AWS y prepara la carpeta | Una vez, al empezar |
| `plan` | Compara lo declarado contra lo que existe y muestra las diferencias. **No cambia nada** | Siempre, antes de aplicar |
| `apply` | Ejecuta los cambios que mostro el plan | Cuando el plan dice lo que esperabas |
| `destroy` | Elimina todo lo que creo | Al terminar la clase |

### 4.3 El state

Terraform guarda en un archivo `terraform.tfstate` que recursos creo y con que IDs. Es como
lo relaciona con la realidad.

Si pierdes ese archivo, Terraform **deja de saber que esos recursos son suyos**: intentara
crearlos de nuevo, y los originales quedaran corriendo sin que nadie los administre,
consumiendo tu presupuesto. Por eso el state no se borra ni se sube a git.

> El state guarda tambien los valores marcados como `sensitive` (los passwords de esta
> actividad). Esa es la otra razon por la que nunca se versiona.

### 4.4 Terraform y Docker resuelven cosas distintas

| | Terraform | Docker |
|---|---|---|
| Se encarga de | La infraestructura: maquinas, red, almacenamiento | Los servicios que corren dentro de las maquinas |
| En esta actividad | EC2, S3, Security Groups | Las seis plataformas del caso, PostgreSQL y HAProxy |

El puente entre ambos es el **`user_data`**: un script que EC2 ejecuta la primera vez que la
instancia arranca, y que instala Docker y levanta los contenedores. Terraform lo genera a
partir de una plantilla y le inyecta los datos que solo se conocen al momento de crear (por
ejemplo, la IP de la instancia de aplicacion).

## 5) Paso 1 - Credenciales del laboratorio

En el Learner Lab, boton **AWS Details** > **AWS CLI**. Copia el bloque completo a un archivo
llamado `.aws-credentials` dentro de `Casos/AndysMotors/infra`:

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

Tres cosas importantes:

1. Ese archivo esta en `.gitignore`: **nunca** debe llegar al repositorio.
2. Son credenciales **temporales**. Expiran al cerrar la sesion del lab. Cuando veas el error
   `ExpiredToken`, vuelve aqui y copialas de nuevo.
3. El `aws_session_token` es obligatorio. Si lo omites, casi todo va a fallar.

Aprovecha de descargar tambien **`labsuser.pem`** desde el mismo panel, y dale permisos:

```bash
chmod 400 labsuser.pem
```

## 6) Paso 2 - Configurar tus variables

```bash
cp terraform.tfvars.example terraform.tfvars
curl -s ifconfig.me          # tu IP publica
```

Edita `terraform.tfvars` con tres valores:

| Variable | Que poner |
|---|---|
| `admin_cidr` | Tu IP publica en formato `/32`, por ejemplo `"200.83.12.45/32"` |
| `db_password` | Entre 12 y 41 caracteres: letras, numeros, `_`, `.`, `~`, `-` |
| `grafana_admin_password` | Minimo 12 caracteres, mismo juego de caracteres |

`admin_cidr` es el unico origen que podra entrar por SSH, Grafana y Prometheus. Ponerlo en
`0.0.0.0/0` significa abrirle tu laboratorio a todo Internet: no lo hagas.

> Si tu IP cambia (te cambiaste de red, se reconecto el router), tendras que actualizar
> `admin_cidr` y volver a aplicar. No es un error: es el firewall haciendo su trabajo.

## 7) Paso 3 - init y plan: mirar antes de crear

```bash
./scripts/tf.sh init
```

Descarga el proveedor de AWS. Se hace una sola vez.

```bash
./scripts/tf.sh plan
```

**Este comando no crea nada.** Lee la salida con calma, porque es el habito mas importante de
toda la actividad: en un entorno con presupuesto limitado, el `plan` es lo que evita que
descubras que creaste algo caro despues de haberlo creado.

Fijate en:

- La linea final: `Plan: N to add, 0 to change, 0 to destroy.`
- Los recursos con `+` (se van a crear).
- Los valores que aparecen como `(known after apply)`: son datos que todavia no existen,
  como la IP publica de una instancia que aun no se crea.
- Los valores `(sensitive value)`: Terraform oculta los passwords en la salida.

**Anota cuantos recursos va a crear.** Lo vas a necesitar en las evidencias.

## 8) Paso 4 - apply: crear la infraestructura

```bash
./scripts/tf.sh apply
```

Muestra el plan otra vez y pide confirmacion: hay que escribir `yes` completo.

Demora alrededor de un minuto. Al terminar veras las **salidas** (`outputs`) con las URLs y
comandos que necesitas. Puedes volver a verlas cuando quieras:

```bash
./scripts/tf.sh output
```

> **Las instancias aparecen como `running` antes de estar listas.** El `user_data` todavia
> tiene que instalar Docker y descargar las imagenes de los contenedores: son entre 2 y 4
> minutos mas. Si el sitio no responde de inmediato, no esta roto.

## 9) Paso 5 - Verificar la plataforma

Con la IP del balanceador que entrego `terraform output`:

```bash
# Portada del sitio publico
curl -s http://<IP_BORDE>/

# Catalogo: el sitio web pide los datos a la plataforma de stock
curl -s http://<IP_BORDE>/api/catalogo

# Un flujo de negocio completo: crea el cliente y su oportunidad en el CRM
curl -s -X POST http://<IP_BORDE>/api/contacto \
  -H 'Content-Type: application/json' \
  -d '{"nombre":"Camila Rojas","monto_clp":18990000}'
```

La pagina de estado del balanceador muestra si cada plataforma esta viva:

```
http://<IP_BORDE>:8404/stats
```

Si algo no responde, entra a mirar el arranque de esa maquina:

```bash
ssh -i labsuser.pem ec2-user@<IP_DE_ESA_MAQUINA>

sudo tail -f /var/log/cloud-init-output.log     # avance del user_data
cd /opt/andys && sudo docker compose ps         # contenedores de esa plataforma
```

> El arranque toma entre 3 y 6 minutos: cada servidor instala Docker, descarga el entorno
> desde S3 y construye la imagen de las aplicaciones.

## 10) Paso 6 - Reconocer la telemetria disponible

Antes de monitorear algo hay que saber que hay para monitorear. Ejecuta:

```bash
terraform output endpoints_de_metricas
```

Te devuelve las direcciones que habria que scrapear. Recorrelas a mano:

```bash
# Metricas tecnicas y de negocio de una plataforma
curl -s http://<IP_BORDE>/stock/api/stock > /dev/null       # genera algo de trafico
ssh -i labsuser.pem ec2-user@<IP_STOCK> curl -s localhost:8082/metrics | grep -v '^#' | head -20

# Metricas del balanceador: mas de 200 familias, sin instalar nada
curl -s http://<IP_BORDE>:8404/metrics | grep -c '^# TYPE'
curl -s http://<IP_BORDE>:8404/metrics | grep '^haproxy_server_status.*UP'
```

Identifica y anota, para cada plataforma, **una metrica tecnica y una de negocio**. El
[catalogo completo](../../Casos/AndysMotors/demo/README.md#4-qué-telemetría-expone) esta en
el README del entorno. Dos ejemplos:

| Metrica | Que tipo es | Que responde |
|---|---|---|
| `http_requests_total{status_code="500"}` | tecnica | Esta fallando el servicio? |
| `agendamientos_confirmados_total` | de negocio | Se estan registrando las visitas? |

> **Nota importante**: no hay Prometheus desplegado. Si en tu `terraform.tfvars` dejaste
> `enable_monitoring = true`, si lo hay, y puedes revisar `http://<IP_MONITOREO>:9090/targets`
> como referencia. Construir tu propio stack es el objetivo de otra actividad.

## 11) Paso 7 - La misma maquina, dos miradas

Esta es la observacion central de la unidad, y ahora la puedes hacer con datos propios.

Primero genera trafico sostenido contra la plataforma:

```bash
cd ../../Casos/AndysMotors/demo
./scripts/generar_trafico.py --url http://<IP_BORDE> --hora-inicio 10 --factor 1 --duracion 900
```

Mientras corre, abre la consola de AWS > **CloudWatch** > **Metrics** > **EC2** >
**Per-Instance Metrics**, busca el servidor de la plataforma de agenda y grafica
`CPUUtilization`. En paralelo, mira las metricas que expone esa misma maquina:

```bash
ssh -i labsuser.pem ec2-user@<IP_AGENDA> \
  curl -s localhost:8083/metrics | grep -E '^agendamientos_'
```

Ahora rompe el negocio **sin tocar la infraestructura**:

```bash
export AGENDA_ADDR=<IP_PRIVADA_AGENDA>
./scripts/escenario.sh activar agenda_silenciosa
```

Deja correr el trafico unos minutos mas y responde, con evidencia:

| Pregunta |
|---|
| Que metricas de la instancia te entrega CloudWatch sin instalar nada? |
| Cada cuanto publica CloudWatch un punto de datos? |
| Aparece el uso de **memoria RAM** en CloudWatch? A que se debe? |
| Cambio **algo** en CloudWatch cuando activaste `agenda_silenciosa`? Y en `haproxy_backend_http_responses_total{code="5xx"}`? |
| Que le paso a `agendamientos_solicitados_total` frente a `agendamientos_confirmados_total`? |
| Cuantos agendamientos se perdieron, y cuanto habria tardado el equipo en enterarse mirando solo CPU y memoria? |

Acuerdate de apagar el escenario al terminar:

```bash
./scripts/escenario.sh apagar-todo
```

Guarda las capturas de CloudWatch y de las metricas de negocio: son la evidencia principal
de esta actividad.

## 12) Paso 8 - Leer el codigo

Abre los archivos de [`infra/`](../../Casos/AndysMotors/infra) y responde. Todas las
respuestas estan en los comentarios del propio codigo.

| # | Archivo | Pregunta |
|---|---|---|
| 1 | `data.tf` | Por que el proyecto **no crea** un rol de IAM, y que usa en su lugar? |
| 2 | `data.tf` | Por que se usa la VPC por defecto en vez de crear una propia? |
| 3 | `security.tf` | El puerto 9100 no se abre a Internet. Desde donde se permite, y por que importa? |
| 4 | `security.tf` | Por que los Security Groups se referencian entre si por ID y no por IP? |
| 5 | `compute.tf` | Que hace `user_data_replace_on_change` y por que esta en `true`? |
| 6 | `locals.tf` | Por que las IP privadas se calculan con `cidrhost()` en vez de dejar que AWS las asigne? |
| 6b | `locals.tf` | Que cambia entre `topologia = "completa"` y `"compacta"`, y que NO cambia? |
| 6c | `storage.tf` | Por que el codigo del entorno viaja por S3, y no clonando el repositorio ni dentro del `user_data`? |
| 7 | `storage.tf` | Que hace `force_destroy` y por que tiene sentido en un laboratorio? |
| 8 | `storage.tf` | Que problema evita el bloque `public_access_block`? |
| 9 | `variables.tf` | Por que `db_password` no admite los caracteres `/`, `@` ni `"`? |
| 10 | `database.tf` | Por que `enable_rds` viene apagado por defecto? Da las tres razones. |
| 11 | `borde/haproxy.cfg` (en `demo/`) | Que hace `init-addr last,libc,none` y que problema evita? |

## 13) Paso 9 - Modificar la infraestructura

Aqui se entiende de verdad para que sirve todo esto.

**a) Idempotencia.** Sin cambiar nada, ejecuta:

```bash
./scripts/tf.sh plan
```

Debe decir `No changes. Your infrastructure matches the configuration.` Aplicar dos veces la
misma configuracion no duplica nada.

**b) Un cambio pequenio.** Edita `terraform.tfvars` y agrega:

```hcl
allow_public_web = true
```

```bash
./scripts/tf.sh plan
```

Observa que Terraform propone **modificar solo la regla del puerto 80**, y no volver a crear
la instancia. Aplicalo y comprueba desde otra red (por ejemplo, los datos moviles del
telefono) que el sitio ahora si responde.

**c) Un cambio grande.** Ahora prueba (sin aplicar) cambiar `instance_type` a `t3.small`:

```bash
./scripts/tf.sh plan
```

Fijate en la diferencia: aparece `# forces replacement`. Algunos atributos se pueden cambiar
en caliente y otros obligan a **destruir y recrear** el recurso. Saber cuales son cuales es
lo que separa un cambio inofensivo de una caida de produccion.

Deja `instance_type` como estaba antes de continuar.

## 14) Paso 10 (opcional) - Encender RDS

```hcl
# terraform.tfvars
enable_rds = true
```

```bash
./scripts/tf.sh apply
```

**Lee esto antes de ejecutarlo:**

- Tarda entre **10 y 15 minutos**. Es justo donde suelen expirar las credenciales del lab:
  copialas frescas inmediatamente antes.
- La instancia de aplicacion **se recrea**, porque necesita el endpoint de RDS para
  configurarse.
- Es lo que mas presupuesto consume de todo el proyecto.

Una vez arriba, el ejercicio que lo justifica: compara en CloudWatch las metricas que
entrega RDS (`CPUUtilization`, `DatabaseConnections`, `FreeStorageSpace`) contra las que
entrega el `postgres-exporter` en tu Grafana. Que te da cada uno, y que pierdes al delegar la
base de datos en un servicio administrado?

## 15) Paso 11 - Destruir

**Al terminar la clase, siempre:**

```bash
./scripts/tf.sh destroy
```

Escribe `yes` para confirmar. Despues entra a la consola de AWS y comprueba que no quedo
nada: instancias EC2, RDS, **volumenes EBS sueltos** y buckets S3. Un volumen huerfano sigue
costando aunque su instancia ya no exista.

Esta es la ventaja concreta de la infraestructura como codigo: destruir todo cuesta un
comando, y volver a levantarlo identico cuesta otro.

## 16) Evidencias esperadas

1. Captura de la salida de `terraform plan`, mostrando la linea `Plan: N to add`.
2. Captura de `terraform apply` terminado, con las salidas (`outputs`).
3. Captura del sitio de Andys Motors respondiendo en el navegador.
4. Captura de `http://<IP_BORDE>:8404/stats` con todas las plataformas en verde.
5. Una metrica tecnica y una de negocio por plataforma, anotadas (Paso 6).
6. **Las capturas del Paso 7**: CPU en CloudWatch y los contadores de negocio de agenda,
   antes y despues de activar `agenda_silenciosa`, con las seis preguntas respondidas.
7. Respuestas a las preguntas de lectura de codigo del Paso 8.
8. Captura del `plan` del Paso 9c, donde se ve `forces replacement`.
9. Captura de `terraform destroy` completado.

## 17) Troubleshooting

Los errores mas frecuentes de este entorno, con su causa y solucion, estan en el
[README de `infra/`, seccion 11](../../Casos/AndysMotors/infra/README.md#11-troubleshooting).

Los cuatro que veras casi seguro:

| Error | Que hacer |
|---|---|
| `ExpiredToken` | Copiar de nuevo las credenciales del panel **AWS Details** (Paso 1) |
| `InvalidKeyPair.NotFound` | Descargar `labsuser.pem`, o ajustar `key_name` al nombre real |
| El sitio no responde recien aplicado | Esperar 3-6 minutos: el `user_data` sigue corriendo |
| Una plataforma sale DOWN en `:8404/stats` | Sus contenedores aun no arrancan. Revisar `docker compose ps` en esa maquina |
| `VcpuLimitExceeded` al aplicar | La topologia completa pide 7 u 8 instancias: usar `topologia = "compacta"` |

## 18) Checklist de verificacion

- [ ] `.aws-credentials` creado y **no** versionado.
- [ ] `terraform.tfvars` con tu IP real en `admin_cidr` (no `0.0.0.0/0`).
- [ ] `./scripts/tf.sh init` completado sin errores.
- [ ] `plan` leido y entendido **antes** del primer `apply`.
- [ ] `apply` completado y salidas registradas.
- [ ] El sitio de Andys Motors responde por el balanceador.
- [ ] Un flujo de negocio completo (`POST /api/contacto`) funciona de punta a punta.
- [ ] Todas las plataformas aparecen en verde en `:8404/stats`.
- [ ] `terraform output endpoints_de_metricas` listado y recorrido a mano.
- [ ] Identificada una metrica tecnica y una de negocio por plataforma.
- [ ] Escenario `agenda_silenciosa` activado, observado y vuelto a apagar.
- [ ] Comparacion CloudWatch contra metricas de negocio, con las seis preguntas respondidas.
- [ ] Las preguntas de lectura de codigo respondidas.
- [ ] Idempotencia comprobada: un `plan` sin cambios dice `No changes`.
- [ ] Diferencia entre un cambio en caliente y uno que fuerza reemplazo, comprobada.
- [ ] `terraform destroy` ejecutado y consola de AWS revisada sin recursos sobrantes.
