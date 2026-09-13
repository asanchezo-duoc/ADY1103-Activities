# EA2 - Act 2.3: ServerC, Node Exporter y PromQL en profundidad

Guia paso a paso para incorporar un **tercer servidor (ServerC)** al stack de monitoreo que
ya viene funcionando de [Act2-1](../Act2-1) y [Act2-2](../Act2-2), medir su sistema
operativo con **Node Exporter**, y usar **PromQL** para convertir esas metricas crudas en
informacion operativa.

> **Depende de [EA2/Act2-2](../Act2-2)**: se asume que ya tienes ServerA (Prometheus +
> Grafana) arriba, ServerB (la API) siendo scrapeado, y al menos un dashboard creado en
> Grafana. Aqui **no se toca nada de lo anterior**: solo se agrega un servidor nuevo y un
> job nuevo de scraping.

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Arquitectura](#2-arquitectura)
3. [Requisitos previos](#3-requisitos-previos)
4. [Estructura del proyecto](#4-estructura-del-proyecto)
5. [Paso 1 - Preparar ServerC](#5-paso-1---preparar-serverc)
6. [Paso 2 - Levantar Node Exporter](#6-paso-2---levantar-node-exporter)
7. [Paso 3 - Leer la data cruda en /metrics](#7-paso-3---leer-la-data-cruda-en-metrics)
8. [Paso 4 - Registrar el job 'node' en Prometheus](#8-paso-4---registrar-el-job-node-en-prometheus)
9. [Paso 5 - Inyectar carga en ServerC](#9-paso-5---inyectar-carga-en-serverc)
10. [Paso 6 - Explorar con Grafana Explore](#10-paso-6---explorar-con-grafana-explore)
11. [Paso 7 - Catalogo de metricas: las que usamos y las que hay que buscar](#11-paso-7---catalogo-de-metricas-las-que-usamos-y-las-que-hay-que-buscar)
12. [Paso 8 - Ejercicios de PromQL](#12-paso-8---ejercicios-de-promql)
13. [Paso 9 - Agregacion: de muchas series a un numero util](#13-paso-9---agregacion-de-muchas-series-a-un-numero-util)
14. [Paso 10 - Dashboard de ServerC](#14-paso-10---dashboard-de-serverc)
15. [Security Groups de AWS](#15-security-groups-de-aws)
16. [Troubleshooting](#16-troubleshooting)
17. [Checklist de verificacion](#17-checklist-de-verificacion)
18. [Apagar / limpiar](#18-apagar--limpiar)

---

## 1) Objetivo de la actividad

Que el alumno sea capaz de:

- Explicar que es un **Exporter** y por que Prometheus lo necesita.
- Desplegar **Node Exporter** en un servidor nuevo (ServerC), rompiendo el aislamiento del
  contenedor con montajes de `/proc` y `/sys` en **solo lectura**.
- Leer e interpretar el formato de **texto plano** de `/metrics` (`# HELP`, `# TYPE`, labels).
- Registrar un nuevo **job** de scraping en Prometheus y validar el target en verde.
- Distinguir **Counter** y **Gauge**, y saber cual se consulta directo y cual necesita `rate()`.
- Usar **Grafana Explore** para descubrir metricas que no conocia, sin memorizar nombres.
- Construir consultas PromQL con operadores matematicos, funciones de tiempo y funciones de
  **agregacion** (`sum`, `avg`, `by`, `topk`).
- Elegir el **tipo de grafico** correcto para cada tipo de consulta.

## 2) Arquitectura

ServerC es el "servidor observado": no corre aplicaciones de negocio, solo publica el
estado de su propio sistema operativo.

```
                        PULL (puerto 8080, /metrics)
   +-------------+  <-----------------------------------  +-----------+
   |   ServerA   |                                         |  ServerB  |
   | Prometheus  |                                         |    API    |
   |  + Grafana  |                                         +-----------+
   +-------------+
        |   ^
        |   |  PULL (puerto 9100, /metrics)   <---- lo nuevo de esta actividad
        |   +-------------------------------------  +--------------------------+
        |                                           |        ServerC           |
        |                                           |  Node Exporter (Docker)  |
        |                                           |  mide CPU/RAM/disco/red  |
        |                                           |  del sistema operativo   |
        |                                           +--------------------------+
        |
        v  PUSH (remote_write, puerto 9090)
   +----------------------+
   | Grafana Alloy (host) |   <---- opcional, de Act2-1
   +----------------------+
```

Fijate en el contraste, porque es el corazon conceptual de la unidad:

| | Quien inicia la conexion | Aparece en `/targets` | Ejemplo en este lab |
|---|---|---|---|
| **PULL** | Prometheus va a buscar los datos | Si, como target UP/DOWN | ServerB (API) y **ServerC (Node Exporter)** |
| **PUSH** | El agente empuja los datos | No, llegan por `remote_write` | Grafana Alloy (Act2-1, Paso 8) |

Node Exporter y Alloy miden practicamente lo mismo (`node_*`), pero por caminos opuestos.
Tenerlos a ambos corriendo permite ver la diferencia en vivo.

## 3) Requisitos previos

- **Act2-1 y Act2-2 completadas**: ServerA arriba (`docker compose ps` muestra Prometheus y
  Grafana en `Up`) y accesible en `http://<IP_SERVERA>:9090` y `:3000`.
- Un servidor Linux para ServerC, con Docker Engine + Docker Compose v2. Puede ser:
  - una **tercera instancia EC2** (lo ideal: se ve el modelo distribuido real), o
  - **la misma maquina donde corre ServerA** (ver la tabla del Paso 4 para la direccion a usar).
- `curl` disponible.
- Python 3 (sin dependencias externas) si vas a usar `scripts/promql_lab.py`.

## 4) Estructura del proyecto

```
EA2/Act2-3/
├── ServerC/
│   └── docker-compose.yml        # Node Exporter con los montajes y flags correctos
├── prometheus/
│   └── job-serverC.yml           # bloque a pegar en el prometheus.yml de ServerA
├── scripts/
│   ├── inject_load.sh            # genera carga de CPU y de red en ServerC
│   └── promql_lab.py             # explora el catalogo de metricas y autoverifica el lab
├── examples/
│   └── serverc-node.json         # dashboard de Grafana de referencia (importable)
└── README.md
```

## 5) Paso 1 - Preparar ServerC

Si ServerC es una instancia EC2 nueva:

```bash
# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin curl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # cerrar y volver a abrir la sesion SSH tras esto

# Amazon Linux 2023
sudo dnf install -y docker curl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Verificar y copiar la carpeta de la actividad:

```bash
docker compose version      # debe responder v2.x
git clone <url-del-repo> && cd ADY1103-Activities/EA2/Act2-3
# o bien: scp -r EA2/Act2-3 usuario@<IP_SERVERC>:~/
```

Anota la **IP privada** de ServerC (`hostname -I` o la consola de EC2): la vas a necesitar
en el Paso 4.

## 6) Paso 2 - Levantar Node Exporter

```bash
cd ServerC
docker compose up -d
docker compose ps
# serverC-node-exporter   Up
```

Abre `ServerC/docker-compose.yml` y revisa los tres bloques comentados, porque son
exactamente lo que se evalua:

| Bloque | Dimension que libera | Por que importa |
|---|---|---|
| `network_mode: host` | **red** | sin esto, `node_network_*` reporta las interfaces *del contenedor* (una `eth0` virtual con unos pocos KB) en vez de la tarjeta real del servidor. Montar `/proc` no alcanza: `/proc/net` es un enlace a `/proc/self/net`, asi que siempre resuelve al namespace de red del proceso que lee. Como el contenedor usa la red del host, el exporter publica el 9100 directamente y el servicio **no lleva `ports:`** |
| `pid: host` | **procesos** | sin esto, el exporter solo ve sus propios procesos |
| `volumes: /proc, /sys, / con :ro` | **archivos** | le da visibilidad de CPU, memoria y disco reales. `:ro` (read-only) garantiza que el contenedor **lea** el sistema anfitrion pero jamas pueda modificarlo; es lo que hace aceptable el riesgo de exponerle el kernel |
| `--path.procfs`, `--path.sysfs`, `--path.rootfs` | (activa los montajes) | montar los directorios no basta: hay que decirle al exporter que lea desde esas rutas. Sin estos flags sigue leyendo las suyas y terminas midiendo el contenedor |

Dos pruebas rapidas de que la configuracion quedo bien:

```bash
# 1) El arranque que reporta el exporter debe ser el del SERVIDOR, no el del contenedor
date -d @$(curl -s localhost:9100/metrics | awk '/^node_boot_time_seconds /{printf "%d", $2}')
uptime -s          # deben coincidir

# 2) El contador de la interfaz fisica debe coincidir con el del sistema operativo
curl -s localhost:9100/metrics | grep '^node_network_receive_bytes_total{device="eth0"}'
grep -E '^\s*eth0' /proc/net/dev | awk '{print $2}'    # mismo orden de magnitud
```

Si la segunda prueba da valores muy distintos (unos pocos KB contra cientos de MB), falta
`network_mode: host`: estas midiendo la red del contenedor.

## 7) Paso 3 - Leer la data cruda en /metrics

Antes de graficar nada, hay que entender el texto plano que produce el exporter.

```bash
curl -s localhost:9100/metrics | head -30
```

Tambien se puede abrir en el navegador: `http://<IP_SERVERC>:9100/metrics` (requiere que el
Security Group permita tu IP en el puerto 9100; ver seccion 15).

Anatomia de lo que vas a ver:

```
# HELP node_memory_MemTotal_bytes Memory information field MemTotal_bytes.   <- 1
# TYPE node_memory_MemTotal_bytes gauge                                      <- 2
node_memory_MemTotal_bytes 8.32557568e+09                                    <- 3
node_cpu_seconds_total{cpu="0",mode="idle"} 145203.41                        <- 4
node_cpu_seconds_total{cpu="1",mode="idle"} 144987.02
```

1. `# HELP` -> descripcion legible de para que sirve la metrica.
2. `# TYPE` -> el tipo: `counter`, `gauge`, `histogram` o `summary`.
3. La **serie**: nombre + valor actual. Esta no tiene labels.
4. Aqui la misma metrica genera **una serie distinta por cada combinacion de labels**
   (`cpu` x `mode`). Cambiar un solo label crea una serie nueva e independiente.

No hay timestamp en ninguna linea: **Prometheus lo agrega en el momento del scrape**.

Ejercicios de lectura (responder con el comando y el resultado):

```bash
# a) Cuantas lineas de metricas publica tu ServerC?
curl -s localhost:9100/metrics | grep -vc '^#'

# b) Cuantas metricas DISTINTAS hay (sin contar cada combinacion de labels)?
curl -s localhost:9100/metrics | grep '^# TYPE' | wc -l

# c) Cuantas son counter y cuantas gauge?
curl -s localhost:9100/metrics | grep '^# TYPE' | awk '{print $4}' | sort | uniq -c

# d) Cuantos nucleos tiene el servidor, segun la metrica de CPU?
curl -s localhost:9100/metrics | grep '^node_cpu_seconds_total{' | grep 'mode="idle"' | wc -l
```

## 8) Paso 4 - Registrar el job 'node' en Prometheus

Encender el exporter no basta: hay que declararlo en el "cerebro" del sistema. Esto se hace
**en ServerA**, no en ServerC.

1. Abrir `EA2/Act2-1/ServerA/prometheus/prometheus.yml`.
2. Pegar al final, dentro de `scrape_configs:`, el bloque que esta en
   [`prometheus/job-serverC.yml`](./prometheus/job-serverC.yml) (respetando la indentacion
   de 2 espacios).
3. Reemplazar `REEMPLAZAR_IP_O_HOST_SERVERC` segun el escenario:

| Escenario | Valor a usar |
|---|---|
| ServerC es otra instancia EC2 | IP **privada** de ServerC, ej. `10.0.1.30:9100` |
| ServerC es la misma maquina Linux que ServerA | `172.17.0.1:9100` (IP del bridge de Docker) o la IP privada del host |
| ServerC es la misma maquina, con Docker Desktop (Mac/Windows) | `host.docker.internal:9100` |

4. Recargar Prometheus **sin reiniciarlo** (ServerA lo levanta con `--web.enable-lifecycle`):

```bash
curl -X POST http://localhost:9090/-/reload
```

5. Verificar en `http://<IP_SERVERA>:9090/targets`:
   - debe aparecer un tercer job llamado **`node`**, en estado **UP** (verde),
   - con `Last Scrape` actualizandose cada 15 segundos.

6. Autoverificacion rapida desde la linea de comandos:

```bash
python3 scripts/promql_lab.py check
# (si lo corres desde ServerC, agrega: --prometheus http://<IP_SERVERA>:9090)
```

> Este es el primer punto de evidencia de la actividad: captura de `/targets` con el job
> `node` en verde, y captura del endpoint `:9100/metrics` mostrando `# HELP` y `# TYPE`.

## 9) Paso 5 - Inyectar carga en ServerC

Un servidor ocioso produce lineas planas, y con lineas planas no se aprende PromQL. El
script incluido genera carga real de CPU y de red, sin instalar nada:

```bash
cd scripts
./inject_load.sh --duration 600           # 10 minutos, todos los nucleos, CPU + red
./inject_load.sh --cpus 2 --no-net        # solo CPU
./inject_load.sh --no-cpu                 # solo red
./inject_load.sh --help
```

Que hace:

- **CPU**: lanza un bucle ocupado por nucleo. El kernel deja de contabilizar tiempo en
  `mode="idle"` y lo pasa a `mode="user"`, que es justo lo que mide la formula de CPU.
- **Red**: descarga en bucle un archivo hacia `/dev/null`, subiendo
  `node_network_receive_bytes_total` en la interfaz fisica.

Al terminar (o con Ctrl+C) mata todo lo que lanzo. **Deja esta carga corriendo en una
terminal** mientras haces los pasos 6 a 9 en otra ventana.

> La grafica no vuelve a cero apenas cortas la carga: `rate()` promedia toda su ventana, asi
> que baja de a poco durante los siguientes minutos. Ese "arrastre" es el efecto de suavizado
> que se ve en el Paso 8.

## 10) Paso 6 - Explorar con Grafana Explore

Nadie se aprende de memoria los nombres de las metricas. **Explore** es la herramienta de
Grafana para descubrirlas y probar consultas antes de construir un panel: es un banco de
pruebas, no guarda nada y no ensucia tus dashboards.

### Abrirlo

Menu lateral > **Explore** (icono de brujula). Arriba a la izquierda, elegir el datasource
**Prometheus**.

### Los dos modos de la barra de consulta

| Modo | Cuando usarlo |
|---|---|
| **Builder** | Para descubrir. Armas la consulta con menus desplegables: eliges la metrica, agregas filtros de label, agregas operaciones (`rate`, `sum by`...). Grafana escribe el PromQL por ti. |
| **Code** | Para escribir directo, con autocompletado. Es el modo que vas a usar cuando ya sepas lo que quieres. |

Se alterna con el boton **Builder / Code** arriba a la derecha de la barra de consulta. Truco
util: arma la consulta en **Builder** y luego cambia a **Code** para *ver el PromQL que se
genero*. Es la forma mas rapida de aprender la sintaxis.

### Descubrir metricas

1. En modo **Builder**, haz clic en el desplegable **Metric** (o en el boton
   **Metrics explorer** si tu version lo ofrece).
2. Escribe un pedazo del nombre, por ejemplo `memory`, y mira la lista filtrada.
3. Al posarte sobre cada metrica, Grafana muestra su **descripcion** (el `# HELP`) y su
   **tipo** (`# TYPE`). Es la misma informacion que leiste en crudo en el Paso 3, pero
   navegable.
4. En **Label filters**, elige `job` = `node` para ver solo las metricas de ServerC.

### Instant contra Range: por que a veces no aparece el grafico

Junto al boton de ejecutar hay un selector de tipo de consulta:

| Tipo | Que devuelve | Como se ve |
|---|---|---|
| **Instant** | un solo valor por serie (vector instantaneo): la foto del ahora | tabla |
| **Range** | todos los valores de la ventana de tiempo elegida | grafico |

Si escribes una consulta valida y solo ves una tabla, probablemente tengas **Instant**
seleccionado. Para las consultas con `rate()` que veremos abajo, usa siempre **Range**.

### Comparar dos consultas lado a lado

El boton **Split** (arriba a la derecha) divide la pantalla en dos paneles de Explore
independientes, con el tiempo sincronizado. Es la mejor forma de ver la diferencia entre
`rate()` e `irate()` del ejercicio E6.

### Otras cosas que conviene conocer

- **Query history**: pestania inferior con todas las consultas que ejecutaste en la sesion.
  Sirve para recuperar la que funcionaba antes de que la rompieras.
- **Add to dashboard** (arriba a la derecha): convierte la consulta que estas probando en un
  panel de un dashboard, nuevo o existente. Este es el flujo de trabajo real: *explorar
  primero, construir el panel despues*.
- **Shift + Enter** ejecuta la consulta sin soltar el teclado.
- El selector de tiempo y el auto-refresh funcionan igual que en un dashboard.

## 11) Paso 7 - Catalogo de metricas: las que usamos y las que hay que buscar

Node Exporter publica **mas de mil series** por servidor. Esta seccion primero te da las que
vas a usar, y despues te manda a buscar el resto por tu cuenta.

### 11.1 Herramienta de apoyo

```bash
# Cuantas metricas distintas tiene Prometheus guardadas de ServerC
python3 scripts/promql_lab.py list

# Buscar por texto (equivalente a lo que haces en el Metrics explorer de Grafana)
python3 scripts/promql_lab.py list memory
python3 scripts/promql_lab.py list network

# Ver HELP, TYPE, labels y series actuales de una metrica concreta
python3 scripts/promql_lab.py describe node_context_switches_total
```

Si lo corres desde ServerC, agrega `--prometheus http://<IP_SERVERA>:9090`.

### 11.2 Las metricas que usa este laboratorio

| Metrica | Tipo | Labels clave | Que mide |
|---|---|---|---|
| `node_cpu_seconds_total` | counter | `cpu`, `mode` | Segundos que cada nucleo paso en cada modo (`user`, `system`, `idle`, `iowait`...). **No es un porcentaje**: hay que derivarlo. |
| `node_memory_MemTotal_bytes` | gauge | - | RAM fisica total del servidor. |
| `node_memory_MemAvailable_bytes` | gauge | - | RAM realmente disponible para procesos nuevos. **No confundir con `MemFree`**: `MemAvailable` incluye la cache que el kernel puede liberar, y es la que hay que usar para calcular uso real. |
| `node_filesystem_size_bytes` | gauge | `mountpoint`, `fstype`, `device` | Tamanio total de cada sistema de archivos montado. |
| `node_filesystem_avail_bytes` | gauge | `mountpoint`, `fstype`, `device` | Espacio libre disponible para usuarios no-root. |
| `node_network_receive_bytes_total` | counter | `device` | Bytes recibidos por cada interfaz de red desde el arranque. |
| `node_network_transmit_bytes_total` | counter | `device` | Bytes transmitidos por cada interfaz. |
| `node_load1` / `node_load5` / `node_load15` | gauge | - | Carga promedio del sistema a 1, 5 y 15 minutos. |
| `node_boot_time_seconds` | gauge | - | Momento del arranque, en unixtime. Restado de `time()` da el uptime. |
| `up` | gauge | `job`, `instance` | **No viene del exporter**: la fabrica Prometheus en cada scrape. Vale `1` si el target respondio, `0` si no. |

### 11.3 Metricas para buscar por tu cuenta

Cada fila es una pregunta. Encuentra la metrica que la responde usando el **Metrics explorer
de Explore** o `promql_lab.py list <pista>`, y reporta: **nombre exacto, tipo, y el valor
actual en tu ServerC**.

| # | Pregunta a responder | Pista de busqueda |
|---|---|---|
| 1 | Cuantos procesos hay ejecutandose y cuantos bloqueados esperando I/O? | `procs` |
| 2 | Cuantos cambios de contexto ha hecho el kernel desde el arranque? | `context` |
| 3 | Cuanta RAM esta ocupada por cache y cuanta por buffers? | `memory_Cached`, `memory_Buffers` |
| 4 | Hay swap configurado en ServerC? Cuanto queda libre? | `Swap` |
| 5 | Cuantos bytes se han leido y escrito en los discos? | `disk_read`, `disk_written` |
| 6 | Cuanto tiempo han pasado los discos ocupados atendiendo I/O? | `io_time` |
| 7 | Cuantos descriptores de archivo hay asignados y cual es el maximo del sistema? | `filefd` |
| 8 | Cuantos sockets TCP estan en uso ahora mismo? | `sockstat_TCP` |
| 9 | Cuantos segmentos TCP se han retransmitido? (sintoma de red con perdida) | `Retrans` |
| 10 | Cuantos paquetes ha descartado la pila de red por saturacion? | `softnet_dropped` |
| 11 | Que version de kernel y que distribucion corre ServerC? | `uname` |
| 12 | Que version de Node Exporter esta corriendo? | `build_info` |
| 13 | Cuanto demora cada collector interno del exporter en recolectar? | `scrape_collector_duration` |
| 14 | Hay algun collector fallando? | `scrape_collector_success` |
| 15 | Cuanto se ha desviado el reloj del servidor respecto a NTP? | `timex_offset` |
| 16 | Cuantas entradas tiene la tabla de conexiones del firewall del kernel? | `conntrack` |
| 17 | Tiene ServerC sensores de temperatura expuestos? | `hwmon` |

Tres observaciones que deberian salir de este ejercicio:

- **Las metricas `_info` son un caso especial.** `node_uname_info` siempre vale `1`: el dato
  no esta en el valor, sino en los **labels** (`release`, `sysname`, `nodename`). Se usan
  para aportar contexto, no para graficar.
- **No todas las metricas existen en todos los servidores.** La 17 probablemente no
  devuelva nada en una instancia EC2: no hay sensores de temperatura que exponer en una
  maquina virtual. Que una metrica no exista es en si mismo un dato del entorno.
- **Prometheus agrega metricas propias de cada scrape**, que no vienen del exporter. Buscalas
  con el filtro `scrape` y anota que mide cada una:

| Metrica | Que mide |
|---|---|
| `up` | si el target respondio (1) o no (0) |
| `scrape_duration_seconds` | cuanto demoro el scrape completo |
| `scrape_samples_scraped` | cuantas muestras trajo ese scrape |
| `scrape_series_added` | cuantas series nuevas aparecieron |

`scrape_duration_seconds` y `scrape_samples_scraped` son las metricas que te avisan de que tu
monitoreo se esta volviendo caro antes de que se caiga.

## 12) Paso 8 - Ejercicios de PromQL

Hazlos en orden, en **Explore**, en modo **Code**, con la carga del Paso 5 corriendo. Para
cada uno, registra la consulta, una captura del resultado y **una frase interpretando el
numero**.

### E1 - Gauge directo (vector instantaneo)

```promql
node_memory_MemTotal_bytes
```
Un gauge se consulta directo: el valor actual ya tiene sentido. Con tipo **Instant** lo veras
como tabla. Cambia la unidad del panel a *bytes* para leerlo comodo.

### E2 - El problema del counter crudo

```promql
node_network_receive_bytes_total
```
Una diagonal que sube y nunca baja: es el total historico desde el arranque. **No dice si hay
trafico ahora.** Este es el problema que resuelven las funciones de tasa.

### E3 - La velocidad del counter

```promql
rate(node_network_receive_bytes_total[5m])
```
`[5m]` convierte la consulta en un **vector de rango**: Prometheus toma todos los valores de
los ultimos 5 minutos, calcula cuanto crecio el contador y lo divide por los segundos
transcurridos. Resultado: **bytes por segundo**.

### E4 - Filtrar lo que no sirve

```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m])
```
`lo` es la interfaz de loopback: trafico que la maquina se manda a si misma, irrelevante para
el ancho de banda real. Como el exporter ve la red completa del servidor, si ahi corre Docker
tambien apareceran `docker0`, varias `veth*` y puentes `br-*`: todas son interfaces virtuales
internas. Para quedarte solo con la tarjeta fisica:

```promql
rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m])
```
`=` es igual, `!=` distinto, `=~` coincide con la expresion regular, `!~` no coincide.

### E5 - De bytes a Mbps

```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m]) * 8 / 1024 / 1024
```
PromQL soporta operadores matematicos nativos. `* 8` pasa de bytes a bits; `/1024/1024` lleva
a megabits. Los proveedores de nube facturan en Mbps, no en bytes por segundo.

### E6 - rate() contra irate()

Usa el boton **Split** de Explore y pon una en cada lado:

```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m])
irate(node_network_receive_bytes_total{device!="lo"}[5m])
```

| | Que hace | Para que sirve |
|---|---|---|
| `rate()` | promedia el incremento en toda la ventana | alertas: absorbe micro-picos y evita falsos positivos |
| `irate()` | usa solo las dos ultimas muestras | diagnostico en vivo: revela micro-rafagas que `rate()` suaviza |

### E7 - La tasa de inactividad de la CPU

```promql
rate(node_cpu_seconds_total{mode="idle"}[5m])
```
El sistema operativo no expone un porcentaje de CPU: cuenta **segundos** en cada modo. Un
resultado de `0.30` significa que ese nucleo estuvo libre el 30% del tiempo.

### E8 - Logica inversa: el uso real, por nucleo

```promql
(1 - rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
```
Si estuvo 30% libre, estuvo 70% ocupado. Vas a ver **una linea por nucleo**: ese es el
problema que resuelve el paso siguiente.

### E9 - Consolidar por servidor

```promql
(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100
```
Una sola linea por servidor, aunque tenga 2, 8 o 64 nucleos. Forma equivalente, que veras
escrita a veces en la otra direccion:

```promql
avg by (instance) ((1 - rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```
Dan el mismo resultado porque el promedio es una operacion lineal. Conviene reconocer ambas.

### E10 - Uso de memoria en porcentaje

```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```
Division entre dos gauges. Funciona porque ambas series tienen exactamente los mismos labels:
PromQL las empareja una a una.

### E11 - Proyeccion: cuando se llena el disco

```promql
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4 * 3600)
```
`predict_linear` toma la tendencia de las ultimas 6 horas y extrapola 4 horas hacia adelante.
Si el resultado es **negativo**, al ritmo actual el disco se llena antes de ese plazo. Esta es
la base de las alertas predictivas (avisar *antes* del incidente, no durante).

### E12 - increase() contra rate()

```promql
increase(node_network_receive_bytes_total{device!="lo"}[1h])
```
`increase()` responde "cuanto crecio en total" (bytes en la ultima hora), `rate()` responde
"a que velocidad crece" (bytes por segundo). Son la misma operacion: `increase` es
`rate` multiplicado por los segundos de la ventana. Usa `increase` para reportes y totales,
`rate` para graficos y alertas.

## 13) Paso 9 - Agregacion: de muchas series a un numero util

`rate()` opera sobre el **tiempo**. Las funciones de agregacion operan sobre el **espacio**
(las dimensiones, es decir, los labels). Son dos ejes distintos y se combinan.

### 13.1 Los operadores

| Operador | Que hace | Ejemplo sobre ServerC |
|---|---|---|
| `sum()` | suma las series | `sum(rate(node_network_receive_bytes_total{device!="lo"}[5m]))` - trafico total de todas las interfaces |
| `avg()` | promedia las series | `avg(node_load1)` - carga promedio de la flota |
| `min()` / `max()` | el menor / mayor valor | `max(100 - (node_filesystem_avail_bytes / node_filesystem_size_bytes * 100))` - el disco mas lleno |
| `count()` | cuenta cuantas series hay | `count(node_cpu_seconds_total{mode="idle"})` - cuantos nucleos |
| `stddev()` | desviacion estandar | `stddev by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` - detecta nucleos desbalanceados |
| `topk(n, ...)` | las n series con mayor valor | `topk(3, rate(node_network_receive_bytes_total[5m]))` - las 3 interfaces mas cargadas |
| `bottomk(n, ...)` | las n menores | `bottomk(3, node_filesystem_avail_bytes)` - los 3 discos con menos espacio |
| `quantile(q, ...)` | el percentil q entre las series | `quantile(0.9, node_load1)` - el p90 de carga de la flota |

### 13.2 `by` y `without`: quien sobrevive a la agregacion

Agregar **destruye labels**. Con `by` decides cuales conservar; con `without`, cuales botar.

```promql
# 1. sin agregar: una serie por nucleo y por modo
rate(node_cpu_seconds_total[5m])

# 2. agregado total: UN solo numero, se mezclan nucleos, modos y servidores
sum(rate(node_cpu_seconds_total[5m]))

# 3. conservando el modo: una linea por modo (user, system, idle, iowait...)
sum by (mode) (rate(node_cpu_seconds_total[5m]))

# 4. conservando servidor y modo: lo anterior, separado por maquina
sum by (instance, mode) (rate(node_cpu_seconds_total[5m]))

# 5. lo mismo que 4, escrito al reves: botar solo el label 'cpu'
sum without (cpu) (rate(node_cpu_seconds_total[5m]))
```

> **El error clasico**: usar `avg()` sin `by (instance)` cuando hay varios servidores.
> Prometheus promedia felizmente ServerA, ServerB y ServerC en un solo numero que no
> describe a ninguno. Si tu panel tiene que responder "que servidor esta mal", necesitas
> `by (instance)`.

### 13.3 Agregacion espacial contra agregacion temporal

Se parecen y hacen cosas distintas:

| | Opera sobre | Necesita | Ejemplo |
|---|---|---|---|
| `max(node_load1)` | las **series** (espacio) | vector instantaneo | el servidor mas cargado, ahora |
| `max_over_time(node_load1[1h])` | el **tiempo** | vector de rango `[1h]` | el peak de carga de cada servidor en la ultima hora |

Las funciones `_over_time` (`avg_over_time`, `max_over_time`, `min_over_time`,
`sum_over_time`, `count_over_time`) son la version temporal de cada agregador. Sirven para
suavizar gauges ruidosos, igual que `rate()` suaviza counters:

```promql
avg_over_time(node_load1[30m])
```

### 13.4 Agregacion anidada

Se pueden encadenar. Este es el truco estandar para contar nucleos:

```promql
count(count by (cpu) (node_cpu_seconds_total))
```

De adentro hacia afuera: `count by (cpu)` produce una serie por nucleo (contando sus modos),
y el `count()` exterior cuenta cuantas series quedaron. Resultado: la cantidad de nucleos.

### 13.5 Que grafico usar para cada consulta

| Si tu consulta devuelve... | Tipo de panel | Ejemplo de este lab |
|---|---|---|
| un numero en escala 0-100 con umbrales | **Gauge** | CPU en uso (%), memoria en uso (%) |
| un numero sin escala fija | **Stat** | uptime, cantidad de nucleos |
| un estado binario 1/0 | **Stat** con umbral rojo/verde | `up{job="node"}` |
| varias series a lo largo del tiempo | **Time series** | Mbps de red, load average |
| un ranking corto de elementos | **Bar gauge** | `topk(5, ...)` de discos mas llenos |
| partes que suman un todo | **Time series** apilado (`stacking`) | CPU por modo |
| muchas series con un valor cada una | **Table** (consulta tipo *Instant*) | inventario de sistemas de archivos |
| una distribucion (histogramas) | **Heatmap** | latencia de la API en Act2-2 |

Dos ajustes que hacen la diferencia entre un panel legible y uno inutil:

- **Unidad** (panel > Standard options > Unit): `percent (0-100)`, `bytes(IEC)`,
  `megabits/sec` o `seconds`. Sin unidad, `8325570560` no le dice nada a nadie.
- **Legend** (panel > Legend > legendFormat): `{{device}}` o `nucleo {{cpu}}` en vez del
  nombre completo de la serie con todos sus labels.

## 14) Paso 10 - Dashboard de ServerC

Tienes dos caminos, y conviene hacer los dos en ese orden.

### 14.1 Construirlo desde Explore (el flujo real)

1. Prueba la consulta en **Explore** hasta que devuelva lo que esperas.
2. Boton **Add to dashboard** > *New dashboard*.
3. En el panel recien creado, ajusta titulo, unidad, legend y tipo de visualizacion segun la
   tabla 13.5.
4. Vuelve a Explore para la siguiente consulta y repite con *Existing dashboard*.
5. Guarda el dashboard como **`ServerC - Sistema Operativo`**.

Paneles minimos que debe tener: estado del target, CPU en uso (%), memoria en uso (%), disco
usado (%), ancho de banda en Mbps y load average.

### 14.2 Importar el dashboard de referencia

En [`examples/serverc-node.json`](./examples/serverc-node.json) hay un dashboard ya armado con
16 paneles, incluyendo la comparacion `rate()` contra `irate()` y los ejemplos de agregacion.

```
Dashboards > New > Import > Upload dashboard JSON file
```
Seleccionar el datasource **Prometheus** cuando lo pida.

Tambien se puede dejar cargado automaticamente, copiandolo a la carpeta de provisioning de
Act2-1 y reiniciando Grafana:

```bash
cp examples/serverc-node.json \
   ../Act2-1/ServerA/grafana/provisioning/dashboards/json/
cd ../Act2-1/ServerA && docker compose restart grafana
```

> Comparalo con el tuyo: la idea no es copiarlo, sino contrastar las decisiones de unidad,
> umbral y tipo de panel que tomaste tu con las del ejemplo.

## 15) Security Groups de AWS

Solo hay una regla nueva respecto de Act2-1: el puerto **9100** de ServerC.

### SG de ServerC (Node Exporter)

| Tipo | Puerto | Origen | Motivo |
|---|---|---|---|
| Inbound | 9100/tcp | SG de ServerA (o su IP privada) | Permitir que Prometheus haga scraping de `/metrics` |
| Inbound | 9100/tcp | tu IP de administracion (temporal) | Ver la data cruda en el navegador durante el Paso 3 |
| Inbound | 22/tcp | tu IP de administracion | SSH |

### SG de ServerA (sin cambios respecto de Act2-1)

| Tipo | Puerto | Origen | Motivo |
|---|---|---|---|
| Outbound | 9100/tcp | SG de ServerC | Prometheus va a buscar (pull) las metricas del host |

> `/metrics` de Node Exporter **no tiene autenticacion** y revela informacion detallada del
> servidor (kernel, interfaces, sistemas de archivos, procesos). Abrirlo a `0.0.0.0/0` es
> entregarle un mapa del servidor a cualquiera. Acota siempre el origen, y cierra la regla de
> administracion cuando termines el Paso 3.
>
> Ojo con un detalle de `network_mode: host`: al usar la red del servidor, el exporter escucha
> en **todas** sus interfaces, y Docker ya no filtra nada por ti. En este escenario el
> Security Group es la unica barrera. Si quieres restringirlo tambien en el propio servidor,
> cambia el flag a `--web.listen-address=<IP_PRIVADA_SERVERC>:9100`.

## 16) Troubleshooting

| Sintoma | Causa probable | Solucion |
|---|---|---|
| El job `node` sale **DOWN** en `/targets` | IP mal configurada, puerto 9100 bloqueado, o el contenedor caido | `curl <IP_SERVERC>:9100/metrics` desde ServerA; revisar el Paso 4 y el SG de ServerC |
| El job `node` **no aparece** en `/targets` | El YAML quedo mal indentado, o Prometheus no recargo | `docker exec serverA-prometheus promtool check config /etc/prometheus/prometheus.yml`, luego `curl -X POST http://localhost:9090/-/reload` |
| Las metricas existen pero describen al contenedor, no al servidor | Faltan los flags `--path.procfs` / `--path.sysfs` / `--path.rootfs` | Revisar el `command:` del `docker-compose.yml` de ServerC (Paso 2) |
| `node_network_*` muestra una `eth0` con pocos KB en vez del trafico real | Falta `network_mode: host`: se esta midiendo la red del contenedor | Revisar el `docker-compose.yml` de ServerC y correr la prueba 2 del Paso 2 |
| `docker compose up` avisa que `ports` es incompatible con `network_mode: host` | Se agregaron ambos a la vez | Con red del host el puerto se publica solo: quitar la seccion `ports:` y usar `--web.listen-address=:9100` |
| `node_filesystem_*` muestra decenas de montajes raros | Es normal con `--path.rootfs`: el exporter ve **todos** los sistemas de archivos del servidor, incluidos los virtuales | Filtrar por tipo: `{fstype!~"tmpfs\|overlay\|squashfs\|fuse.*\|9p\|rootfs"}`, o ir directo al que importa con `{mountpoint="/"}` |
| La consulta con `rate()` no devuelve nada | La ventana `[...]` es mas corta que el intervalo entre muestras, o el target lleva menos de 2 scrapes arriba | Esperar ~1 minuto y/o ampliar la ventana a `[5m]` |
| El grafico se ve vacio pero la consulta es correcta | Explore esta en modo **Instant** en vez de **Range** | Cambiar el tipo de consulta (Paso 6) |
| `rate()` da un valor enorme y absurdo justo despues de reiniciar el exporter | El counter se reinicio a cero | `rate()` ya corrige los reinicios; si el pico persiste, es el primer scrape tras el reinicio: se normaliza solo |
| La CPU no sube al correr `inject_load.sh` | El script corrio en ServerA/ServerB en vez de ServerC | Ejecutarlo **en ServerC**; verificar con `top` que hay procesos al 100% |
| `promql_lab.py` dice que no puede conectarse a Prometheus | Se esta ejecutando desde ServerC contra `localhost` | Agregar `--prometheus http://<IP_SERVERA>:9090` |
| El dashboard importado sale con todos los paneles vacios | El datasource elegido en la importacion no es el correcto | Reimportar eligiendo **Prometheus**, o editar un panel y corregir el datasource |
| Aparecen metricas `node_*` duplicadas con distinto `job` | Tambien esta corriendo Grafana Alloy (Act2-1, Paso 8) | Es lo esperado: son el mismo dato por dos caminos (pull y push). Filtrar con `{job="node"}` |

## 17) Checklist de verificacion

- [ ] `docker compose up -d` en ServerC deja `serverC-node-exporter` en estado `Up`.
- [ ] `curl localhost:9100/metrics` devuelve texto plano con `# HELP` y `# TYPE`.
- [ ] Respondidas las 4 preguntas de lectura de data cruda del Paso 3.
- [ ] El job **`node`** aparece en `http://<IP_SERVERA>:9090/targets` en estado **UP**.
- [ ] `python3 scripts/promql_lab.py check` termina sin consultas vacias.
- [ ] `inject_load.sh` corre en ServerC y la CPU se ve subir en Prometheus/Grafana.
- [ ] Usado **Explore** en modo Builder y en modo Code, y comprobada la diferencia entre
      consulta *Instant* y *Range*.
- [ ] Identificadas y documentadas al menos **10 de las 17 metricas** del Paso 7.3 (nombre,
      tipo y valor actual).
- [ ] Documentadas las 4 metricas de scrape que genera Prometheus (Paso 7.3).
- [ ] Ejercicios E1 a E12 ejecutados, cada uno con su captura y su interpretacion escrita.
- [ ] Comparados `rate()` e `irate()` lado a lado con el **Split** de Explore.
- [ ] Construidas al menos 3 consultas propias con agregacion (`sum`/`avg`/`topk` + `by`).
- [ ] Dashboard **ServerC - Sistema Operativo** creado desde Explore y guardado.
- [ ] Dashboard de referencia importado y comparado con el propio.

## 18) Apagar / limpiar

```bash
# En ServerC: detener el exporter
cd ServerC && docker compose down

# En ServerA: quitar el job 'node' del prometheus.yml (o dejarlo comentado)
#             y recargar la configuracion
curl -X POST http://localhost:9090/-/reload
```

Si ServerC era una instancia EC2 dedicada, recuerda **terminarla** desde la consola de AWS
para no consumir el credito del Learner Lab. La data historica que alcanzo a recolectar sigue
guardada en el volumen de Prometheus de ServerA.
