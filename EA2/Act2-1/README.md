# EA2 - Act 2.1: Monitoreo con Prometheus, Grafana y Grafana Alloy

Guia paso a paso de la actividad: montar un stack de monitoreo (**ServerA**) que observa
una API de ejemplo (**ServerB**) y, opcionalmente, el host donde corren los servicios
(via **Grafana Alloy**).

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Arquitectura](#2-arquitectura)
3. [Requisitos previos](#3-requisitos-previos)
4. [Estructura del proyecto](#4-estructura-del-proyecto)
5. [Paso a paso](#5-paso-a-paso)
6. [Variables de entorno](#6-variables-de-entorno)
7. [Security Groups de AWS](#7-security-groups-de-aws)
8. [Troubleshooting](#8-troubleshooting)
9. [Checklist de verificacion](#9-checklist-de-verificacion)
10. [Apagar / limpiar el laboratorio](#10-apagar--limpiar-el-laboratorio)

---

## 1) Objetivo de la actividad

Que el alumno sea capaz de:

- Levantar un stack de monitoreo (Prometheus + Grafana) con Docker Compose y volumenes
  persistentes.
- Construir localmente la imagen Docker de una API y exponerle endpoints de `health` y
  `metrics` en formato Prometheus.
- Configurar Prometheus para hacer **pull** (scraping) de esa API.
- Visualizar las metricas en Grafana usando el datasource de Prometheus.
- (Opcional / puntaje extra) Monitorear tambien el **host** con Grafana Alloy, entendiendo
  la diferencia entre el modelo **pull** (Prometheus -> ServerB) y **push** (Alloy ->
  Prometheus).
- Entender que puertos y reglas de Security Group se necesitan si esto se despliega en AWS
  con ServerA y ServerB en instancias EC2 separadas.

## 2) Arquitectura

```
                     PULL (Prometheus scrapea /metrics, puerto 8080)
   +-----------+  <-------------------------------------  +-----------+
   |  ServerA  |                                           |  ServerB  |
   | Prometheus|                                           |    API    |
   | + Grafana |                                           | (Docker)  |
   +-----------+  <-------------------------------------   +-----------+
        ^            PUSH (remote_write, puerto 9090)
        |
   +---------------------+
   | Grafana Alloy (host)|
   | metricas de sistema |
   +---------------------+
```

- **ServerA** corre 2 contenedores (Prometheus y Grafana) via `docker compose`.
- **ServerB** es 1 contenedor (la API), construido a mano con `docker build` (no viene de
  un registry ni de docker-compose).
- **Grafana Alloy** no corre en Docker: se instala directo en el sistema operativo del host
  (por eso el script `.sh`), ya que su objetivo es medir metricas del propio SO.

## 3) Requisitos previos

- Docker Engine + Docker Compose v2 (`docker compose version` debe funcionar).
- Node.js **no es necesario** en tu maquina: el build de ServerB corre dentro del
  contenedor.
- `curl` para probar los endpoints.
- Si vas a desplegar en AWS: 1 o 2 instancias EC2 (Ubuntu recomendado), acceso SSH y
  permisos para editar Security Groups.

## 4) Estructura del proyecto

```
EA2/Act2-1/
├── ServerA/                            # Prometheus + Grafana (docker compose)
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── prometheus/
│   │   └── prometheus.yml              # targets de scraping (pull)
│   └── grafana/provisioning/
│       ├── datasources/datasource.yml  # datasource de Prometheus, autoconfigurado
│       └── dashboards/                 # dashboards autoprovisionados (json/*.json)
├── ServerB/                            # API de ejemplo (Docker, build local)
│   ├── Dockerfile
│   ├── package.json
│   └── src/server.js                   # /health, /api/saludo, /api/productos, /api/error, /api/random, /metrics
├── scripts/
│   ├── install-alloy.sh                # instala Grafana Alloy en el host
│   ├── alloy-config.alloy              # config basica de Alloy (metricas de sistema)
│   ├── generate_traffic.py             # genera trafico/errores de prueba contra ServerB
│   └── backfill_7d_history.py          # backfillea 7 dias de historia sintetica en Prometheus
└── README.md
```

## 5) Paso a paso

### Paso 1 - Construir y levantar ServerB (la API a monitorear)

Primero se levanta ServerB para tener un target real que Prometheus pueda scrapear.

```bash
cd ServerB
docker build -t serverb-api:local .
docker run -d --name serverB -p 8080:8080 serverb-api:local
```

Verificar que responde:

```bash
curl http://localhost:8080/health
# {"status":"ok","uptime_seconds":...}

curl http://localhost:8080/api/saludo
# {"mensaje":"Hola desde ServerB!"}

curl http://localhost:8080/api/productos
# {"productos":[{"id":1,...},{"id":2,...}]}

curl http://localhost:8080/metrics
# Deberias ver metricas tipo:
#   http_requests_total{method="GET",route="/health",status_code="200"} 1
#   http_request_duration_seconds_bucket{...}
#   process_cpu_user_seconds_total ...
```

> `docker inspect --format='{{.State.Health.Status}}' serverB` deberia mostrar `healthy`
> despues de ~15 segundos (definido por el `HEALTHCHECK` del Dockerfile).

### Paso 2 - Configurar el target de ServerB en Prometheus

Editar `ServerA/prometheus/prometheus.yml` y reemplazar el placeholder por la direccion
real de ServerB:

```yaml
- job_name: "serverB-api"
  metrics_path: /metrics
  static_configs:
    - targets: ["REEMPLAZAR_IP_O_HOST_SERVERB:8080"]   # <-- editar esta linea
```

Valores tipicos segun donde corra cada servicio:

| Escenario | Valor a usar |
|---|---|
| ServerA y ServerB en la misma Mac/Windows (Docker Desktop) | `host.docker.internal:8080` |
| ServerA y ServerB en la misma maquina Linux | IP del host, ej. `172.17.0.1:8080` |
| ServerA y ServerB en instancias EC2 distintas | IP **privada** de ServerB, ej. `10.0.1.25:8080` |

### Paso 3 - Levantar ServerA (Prometheus + Grafana)

```bash
cd ServerA
cp .env.example .env
# Editar .env y cambiar GRAFANA_ADMIN_PASSWORD por una clave propia
docker compose up -d
```

Verificar que ambos contenedores esten arriba:

```bash
docker compose ps
# serverA-prometheus   Up
# serverA-grafana      Up
```

### Paso 4 - Verificar que Prometheus esta "pulleando" a ServerB

1. Abrir `http://<IP_SERVERA>:9090/targets` en el navegador.
2. Deberian aparecer 2 jobs: `prometheus` (self) y `serverB-api`, ambos en estado **UP**.
   - Si `serverB-api` sale **DOWN**, revisar el Paso 2 (IP/host mal configurado) y que el
     Security Group de ServerB permita el puerto 8080 desde ServerA (ver seccion 7).
3. Probar una query rapida en `http://<IP_SERVERA>:9090/graph`:
   ```promql
   rate(http_requests_total[1m])
   ```

### Paso 5 - Ver las metricas en Grafana

1. Abrir `http://<IP_SERVERA>:3000` e iniciar sesion con las credenciales de `.env`.
2. El datasource **Prometheus** ya aparece creado (Configuration > Data sources): no hay
   que configurar nada, se provisiono solo al levantar el contenedor.
3. Crear un dashboard de prueba: **Dashboards > New > New Dashboard > Add visualization**,
   elegir el datasource Prometheus y usar como query:
   ```promql
   sum(rate(http_requests_total[1m])) by (route)
   ```
   Esto grafica la tasa de requests por endpoint de ServerB.
4. Generar trafico para ver el grafico moverse:
   ```bash
   for i in $(seq 1 20); do curl -s http://localhost:8080/api/saludo > /dev/null; done
   ```

### Paso 6 (opcional) - Generar trafico y errores de prueba

Los paneles de "tasa de errores" y "requests por status code" (Act2-2) no muestran nada
interesante si ServerB solo recibe trafico exitoso. Para eso ServerB expone dos endpoints
pensados solo para pruebas:

- `GET /api/error` - siempre responde 500.
- `GET /api/random` - responde 200 (85%), 404 (10%) o 500 (5%) al azar, simulando un
  endpoint real con fallas ocasionales.

Probarlos a mano:

```bash
curl -i http://localhost:8080/api/error      # siempre 500
curl -i http://localhost:8080/api/random     # variable
```

O generar carga sostenida con el script incluido (solo libreria estandar de Python, no
requiere `pip install`):

```bash
python3 scripts/generate_traffic.py --duration 120 --rps 10 --error-ratio 0.15
```

Esto pega contra `/health`, `/api/saludo`, `/api/productos`, `/api/random` y (en el
`error-ratio` indicado) `/api/error`, y al final imprime un resumen de status codes.
Mientras corre, revisa en Grafana los paneles de tasa de requests, tasa de errores y
status code: deberian moverse en tiempo real.

### Paso 7 (opcional) - Cargar 7 dias de historia sintetica

Un dashboard recien creado solo tiene los ultimos minutos de datos reales, lo que hace
dificil apreciar tendencias (patron dia/noche, fin de semana, etc). Este script backfillea
7 dias de metricas sinteticas **directo en el TSDB de Prometheus**, usando el mecanismo de
backfill oficial (`promtool tsdb create-blocks-from openmetrics`, incluido en la imagen de
Prometheus), sin necesidad de `remote_write` ni dependencias adicionales.

Se recomienda correrlo **inmediatamente despues** de `docker compose up -d` (recien
levantado ServerA), para que el backfill no se solape con datos reales ya recolectados:

```bash
python3 scripts/backfill_7d_history.py
```

Que hace:

1. Genera un archivo OpenMetrics con una semana de metricas de host (`node_cpu_seconds_total`,
   memoria, disco, red, load average) y de la API (`http_requests_total`,
   `http_request_duration_seconds_*`, `process_*`), con un patron diurno/semanal realista
   (mas trafico en horario de oficina, menos en la madrugada y los fines de semana).
2. Copia el archivo dentro del contenedor `serverA-prometheus` y corre `promtool tsdb
   create-blocks-from openmetrics` para convertirlo en bloques TSDB.
3. Mueve esos bloques a la carpeta de datos de Prometheus.
4. Reinicia el contenedor para que los cargue (los bloques nuevos no se detectan en
   caliente).

Verificar que funciono:

```bash
curl -s 'http://localhost:9090/api/v1/query_range?query=node_load1&start='$(($(date +%s)-604800))'&end='$(date +%s)'&step=3600' | jq '.data.result[0].values | length'
# deberia devolver ~168 (24 horas x 7 dias)
```

O simplemente abrir los dashboards de Grafana con el selector de tiempo en **Last 7 days**.

> Los datos de las metricas de host (`node_*`) del backfill usan las mismas labels que
> generaria Grafana Alloy (Paso 8); si tambien instalaste Alloy, la historia sintetica y
> los datos reales se completan en el tiempo sin quedar duplicados.

### Paso 8 (opcional) - Monitorear el host con Grafana Alloy

En la maquina cuyo sistema operativo quieras observar (CPU/memoria/disco/red):

```bash
cd scripts
export PROMETHEUS_REMOTE_WRITE_URL="http://<IP_SERVERA>:9090/api/v1/write"
sudo -E ./install-alloy.sh
```

Que hace el script:

1. Agrega el repositorio APT de Grafana e instala el paquete `alloy`.
2. Copia `alloy-config.alloy` a `/etc/alloy/config.alloy` (recolecta metricas de CPU,
   memoria, disco, red via `prometheus.exporter.unix`).
3. Guarda `PROMETHEUS_REMOTE_WRITE_URL` en `/etc/default/alloy` para que Alloy sepa a donde
   hacer `remote_write` (push).
4. Habilita e inicia el servicio `alloy` con `systemd`.

Verificar:

```bash
systemctl status alloy
journalctl -u alloy -f
```

En Prometheus (`http://<IP_SERVERA>:9090/graph`), confirmar que llegan metricas del host:

```promql
node_memory_MemAvailable_bytes
```

> Nota: esto usa **push**, no pull, porque Alloy corre en el host y "empuja" sus datos a
> Prometheus (por eso `ServerA/docker-compose.yml` habilita
> `--web.enable-remote-write-receiver`). ServerB en cambio usa **pull**: es Prometheus quien
> va a buscar los datos a `/metrics`.

### Paso 9 (opcional) - Desplegar en AWS con ServerA y ServerB en instancias separadas

1. Crear 2 instancias EC2 (ej. Ubuntu 22.04), una para ServerA y otra para ServerB.
2. Instalar Docker en ambas (`sudo apt-get install docker.io docker-compose-plugin` o el
   script oficial de Docker).
3. Configurar los Security Groups segun la seccion 7 de este README **antes** de levantar
   los contenedores.
4. Copiar la carpeta `ServerA/` a la instancia de ServerA y `ServerB/` a la instancia de
   ServerB (via `scp` o `git clone`).
5. En `ServerA/prometheus/prometheus.yml`, usar la **IP privada** de la instancia de
   ServerB (Paso 2).
6. Repetir los Pasos 1, 3, 4 y 5 de arriba, pero reemplazando `localhost` por la IP publica
   (o privada, segun corresponda) de cada instancia.
7. (Opcional) Ejecutar `scripts/install-alloy.sh` en cualquiera de las dos instancias, o en
   ambas, apuntando `PROMETHEUS_REMOTE_WRITE_URL` a la IP privada de ServerA.

## 6) Variables de entorno

| Variable | Donde se usa | Ejemplo | Descripcion |
|---|---|---|---|
| `GRAFANA_ADMIN_USER` | `ServerA/.env` | `admin` | Usuario admin de Grafana |
| `GRAFANA_ADMIN_PASSWORD` | `ServerA/.env` | clave fuerte | Password admin de Grafana (¡cambiar el default!) |
| `PORT` | ServerB (Dockerfile/env) | `8080` | Puerto donde escucha la API |
| `PROMETHEUS_REMOTE_WRITE_URL` | host con Alloy | `http://<IP_SERVERA>:9090/api/v1/write` | Endpoint de remote_write de Prometheus |

No versionar el archivo `.env` real (solo `.env.example`) en el repositorio.

## 7) Security Groups de AWS

Recomendacion: usar **dos Security Groups**, uno por servidor, y referenciarlos entre si
por **Security Group ID** (no por IP) para que funcione aunque cambien las IPs privadas.

### SG de ServerA (Prometheus + Grafana)

| Tipo | Puerto | Origen | Motivo |
|---|---|---|---|
| Inbound | 3000/tcp | IP/CIDR de administracion (alumnos/profesor) | UI de Grafana |
| Inbound | 9090/tcp | IP/CIDR de administracion (opcional, solo para debug) | UI/API de Prometheus |
| Inbound | 9090/tcp | SG del host que corre Grafana Alloy | Recibir `remote_write` de Alloy |
| Inbound | 22/tcp | IP/CIDR de administracion | SSH |
| Outbound | 8080/tcp | SG de ServerB | Prometheus va a buscar (pull) `/metrics` a ServerB |

### SG de ServerB (API)

| Tipo | Puerto | Origen | Motivo |
|---|---|---|---|
| Inbound | 8080/tcp | SG de ServerA | Permitir que Prometheus haga scraping de `/metrics` |
| Inbound | 22/tcp | IP/CIDR de administracion | SSH |

> Si ServerA y ServerB corren en la **misma** instancia EC2 (mismo host, distintos
> contenedores), no aplica trafico entre Security Groups distintos: solo asegurate de que
> el SG de esa instancia permita el puerto 3000 (Grafana) desde tu IP, y no expongas 9090/8080
> a Internet (`0.0.0.0/0`) salvo que sea estrictamente necesario.

> Regla general de seguridad: nunca usar `0.0.0.0/0` en los puertos 3000/9090/8080 salvo
> para pruebas puntuales; siempre acotar el origen a un CIDR conocido o a otro Security Group.

## 8) Troubleshooting

| Sintoma | Causa probable | Solucion |
|---|---|---|
| Target `serverB-api` sale **DOWN** en `/targets` | IP/host mal configurado en `prometheus.yml`, o puerto 8080 bloqueado | Revisar Paso 2 y el Security Group de ServerB |
| `docker compose up` falla con "port already allocated" | Otro proceso usa el puerto 3000/9090 | Liberar el puerto o cambiar el mapeo en `docker-compose.yml` |
| Grafana pide crear el datasource a mano | El volumen `./grafana/provisioning` no se monto bien | Verificar la ruta del volumen en `docker-compose.yml` y que la carpeta exista |
| `install-alloy.sh` falla con "falta PROMETHEUS_REMOTE_WRITE_URL" | No se exporto la variable antes de correr el script | `export PROMETHEUS_REMOTE_WRITE_URL=...` y volver a correr con `sudo -E` |
| No llegan metricas de host a Prometheus | Prometheus no tiene `--web.enable-remote-write-receiver`, o el SG de ServerA no permite el puerto 9090 desde el host de Alloy | Revisar `docker-compose.yml` y el Security Group de ServerA |
| `docker build` de ServerB falla en `npm install` | Sin conexion a internet en el build, o `package.json` corrupto | Verificar conectividad y el contenido de `ServerB/package.json` |
| `backfill_7d_history.py` termina con "el rango a backfillear se solapa con el head" | El contenedor de Prometheus ya lleva rato corriendo con datos reales | Sube `--end-offset-minutes`, o `docker compose down -v && docker compose up -d` y corre el script de inmediato |
| Tras el backfill, Prometheus no muestra historia y borra bloques como "obsoletos" al iniciar | Los timestamps del archivo OpenMetrics quedaron en milisegundos en vez de segundos | Revisar que `backfill_7d_history.py` no se haya modificado para usar `ts * 1000`; OpenMetrics usa SEGUNDOS |
| `promtool tsdb create-blocks-from openmetrics` falla con "permission denied" | `docker cp` preserva el modo 600 del archivo temporal, y Prometheus corre como usuario `nobody` | Ya resuelto en el script (`os.chmod(local_path, 0o644)` antes de copiar); si lo replicas a mano, aplica el mismo chmod |

## 9) Checklist de verificacion

- [ ] `docker run ... serverb-api:local` responde 200 en `/health`, `/api/saludo`,
      `/api/productos` y `/metrics`.
- [ ] `docker compose up -d` en ServerA levanta Prometheus y Grafana sin errores.
- [ ] `http://<IP_SERVERA>:9090/targets` muestra `serverB-api` en estado **UP**.
- [ ] En Grafana, el datasource **Prometheus** existe sin configuracion manual.
- [ ] Un panel con `rate(http_requests_total[1m])` muestra datos al generar trafico.
- [ ] La data de Prometheus persiste tras `docker compose restart` (no se resetea el
      historico).
- [ ] (Opcional) `scripts/generate_traffic.py` corre sin errores y se ve reflejado en los
      paneles de tasa de errores / status code.
- [ ] (Opcional) `scripts/backfill_7d_history.py` corre sin errores y una query con rango
      de 7 dias (ej. `node_load1`) devuelve datos historicos.
- [ ] (Opcional) Alloy instalado en el host y `node_memory_MemAvailable_bytes` visible en
      Prometheus.
- [ ] (Opcional AWS) Security Groups de ServerA y ServerB configurados segun la seccion 7.

## 10) Apagar / limpiar el laboratorio

```bash
# Detener y eliminar ServerB
docker rm -f serverB

# Detener ServerA (sin borrar los volumenes, la data persiste)
cd ServerA
docker compose down

# Si se quiere borrar TAMBIEN la data historica de Prometheus/Grafana:
docker compose down -v
```
