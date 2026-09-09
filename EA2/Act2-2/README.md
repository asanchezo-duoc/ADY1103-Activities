# EA2 - Act 2.2: Dashboards de Grafana para Servidores y API

Guia paso a paso para crear, en Grafana, el Data Source de Prometheus y dos dashboards
de monitoreo: uno para el **host/servidor** y otro para la **API (ServerB)**. Tambien
incluye como cargar 7 dias de historia sintetica (para que los graficos no se vean vacios
apenas creados) y como exportar los dashboards a JSON para dejarlos respaldados.

> **Depende de [EA2/Act2-1](../../EA2/Act2-1)**: se asume que ya tienes ServerA (Prometheus +
> Grafana) y ServerB corriendo, y que Prometheus ya esta scrapeando `serverB-api`. Los
> paneles de metricas de host requieren ademas que hayas instalado **Grafana Alloy**
> (Paso 8 de Act2-1); si no lo hiciste, esos paneles apareceran vacios (salvo que hayas
> corrido el backfill del Paso 1 de esta guia, que tambien los rellena).

## Indice

1. [Objetivo](#1-objetivo)
2. [Prerrequisitos](#2-prerrequisitos)
3. [Paso 1 - Cargar 7 dias de historia sintetica (opcional pero recomendado)](#3-paso-1---cargar-7-dias-de-historia-sintetica-opcional-pero-recomendado)
4. [Paso 2 - Crear el Data Source de Prometheus](#4-paso-2---crear-el-data-source-de-prometheus)
5. [Paso 3 - Dashboard "Servidores / Host"](#5-paso-3---dashboard-servidores--host)
6. [Paso 4 - Dashboard "API - ServerB"](#6-paso-4---dashboard-api---serverb)
7. [Paso 5 - Ajustes finales del dashboard](#7-paso-5---ajustes-finales-del-dashboard)
8. [Paso 6 - Exportar los dashboards a JSON (respaldo)](#8-paso-6---exportar-los-dashboards-a-json-respaldo)
9. [Checklist de verificacion](#9-checklist-de-verificacion)

---

## 1) Objetivo

- Aprender a conectar Grafana a Prometheus manualmente (el Data Source), entendiendo que
  informacion pide y por que.
- Construir dos dashboards separados, con proposito claro cada uno:
  - **Servidores**: salud del sistema operativo del host (CPU, memoria, disco, red).
  - **API**: comportamiento de ServerB desde el punto de vista de un servicio HTTP
    (trafico, errores, latencia).
- Saber cargar historia sintetica para que los dashboards se vean con tendencia real desde
  el primer momento.
- Saber exportar un dashboard a JSON para tener un respaldo versionable (por ejemplo,
  guardarlo en el repo junto al resto de la actividad).

## 2) Prerrequisitos

- Haber completado **EA2/Act2-1**: ServerA (`docker compose up -d`) y ServerB
  (`docker run ...`) arriba y funcionando.
- Acceso a Grafana en `http://<IP_SERVERA>:3000` con el usuario/clave definidos en
  `ServerA/.env`.
- (Para el dashboard de servidores) Grafana Alloy instalado en el host segun el Paso 8 de
  Act2-1, enviando metricas via `remote_write` a Prometheus. Si no instalaste Alloy, el
  backfill del Paso 1 de esta guia igual te deja esos paneles con datos (historicos).
- Python 3 (sin dependencias extra) si vas a correr el script de backfill del Paso 1.

> Nota: en Act2-1 el Data Source de Prometheus ya queda creado automaticamente via
> "provisioning" (`ServerA/grafana/provisioning/datasources/datasource.yml`). El Paso 2 de
> esta guia lo repite **a mano** con fines didacticos: si el datasource "Prometheus" ya
> existe en tu Grafana, puedes revisarlo igual para entender su configuracion, o crear uno
> nuevo con otro nombre (ej. "Prometheus-manual") para practicar sin romper el existente.

## 3) Paso 1 - Cargar 7 dias de historia sintetica (opcional pero recomendado)

Un stack recien levantado solo tiene los ultimos minutos de datos reales, lo que hace
dificil apreciar tendencias en los dashboards de los Pasos 3 y 4 (patron dia/noche, fin de
semana, etc). Este script incluido en esta misma actividad backfillea 7 dias de metricas
sinteticas **directo en el TSDB de Prometheus**, usando el mecanismo de backfill oficial
(`promtool tsdb create-blocks-from openmetrics`, incluido en la imagen de Prometheus), sin
necesidad de `remote_write` ni dependencias adicionales (solo libreria estandar de Python).

Se recomienda correrlo **inmediatamente despues** de `docker compose up -d` en ServerA
(recien levantado, antes de que junte mucho rato de datos reales):

```bash
cd EA2/Act2-2
python3 scripts/backfill_7d_history.py
```

Que hace, en resumen (el detalle completo esta en el docstring del script y en
`EA2/Act2-1/README.md`, Paso 7, que documenta la misma herramienta):

1. Genera un archivo OpenMetrics con una semana de metricas de host (`node_cpu_seconds_total`,
   memoria, disco, red, load average) y de la API (`http_requests_total`,
   `http_request_duration_seconds_*`, `process_*`), con patron diurno/semanal realista.
2. Copia el archivo dentro del contenedor `serverA-prometheus` y corre `promtool tsdb
   create-blocks-from openmetrics` para convertirlo en bloques TSDB.
3. Mueve esos bloques a la carpeta de datos de Prometheus y reinicia el contenedor para
   que los cargue (los bloques nuevos no se detectan en caliente).

Dos detalles que rompen esto si los tocas sin cuidado:

- El backfill **no puede pisar** el rango de tiempo que Prometheus ya tiene "en memoria"
  (su bloque activo / head). Si el contenedor ya lleva rato corriendo con datos reales,
  sube `--end-offset-minutes`, o levanta el stack de cero
  (`docker compose down -v && docker compose up -d`) y corre el script de inmediato.
- OpenMetrics usa **segundos** en el timestamp de cada sample, no milisegundos. El script
  ya lo maneja bien; si lo modificas, ojo con esto.

Verificar que funciono:

```bash
curl -s 'http://localhost:9090/api/v1/query_range?query=node_load1&start='$(($(date +%s)-604800))'&end='$(date +%s)'&step=3600' | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']['result'][0]['values']))"
# deberia imprimir ~168 (24 horas x 7 dias)
```

> **Importante para los pasos 3 y 4:** las metricas backfilleadas quedan con una muestra
> cada 5 minutos (no cada 15s como el scraping real). Esto obliga a usar ventanas de
> `rate()` mas anchas en las queries (`[20m]` en vez de `[1m]`/`[5m]`) para que no se vean
> "huecos" en el grafico — ya viene explicado y aplicado en las tablas de abajo.

## 4) Paso 2 - Crear el Data Source de Prometheus

1. Entrar a Grafana y, en el menu lateral, ir a **Connections > Data sources**.
2. Click en **Add new data source**.
3. Elegir **Prometheus** de la lista.
4. Completar los campos clave:
   - **Name**: `Prometheus` (o `Prometheus-manual` si ya existe uno provisionado).
   - **Prometheus server URL**: `http://prometheus:9090`
     - Si Grafana corre en el mismo docker-compose que Prometheus (como en Act2-1), se usa
       el nombre del servicio (`prometheus`), porque Docker resuelve ese nombre dentro de la
       red interna `monitoring`.
     - Si Grafana estuviera fuera de esa red, se usaria la IP/host real de ServerA, ej.
       `http://<IP_SERVERA>:9090`.
   - **Access**: `Server` (por defecto), es decir, es el backend de Grafana quien consulta a
     Prometheus, no el navegador del usuario.
5. Dejar el resto de los campos (Auth, TLS, etc.) por defecto, ya que este laboratorio no
   usa autenticacion entre Grafana y Prometheus.
6. Click en **Save & test**. Deberia aparecer un mensaje de exito (ej. "Successfully
   queried the Prometheus API").
7. Si falla: revisar que Prometheus este arriba (`docker compose ps` en ServerA) y que la
   URL sea la correcta (ver tabla de troubleshooting en el README de Act2-1).

## 5) Paso 3 - Dashboard "Servidores / Host"

Crear el dashboard: **Dashboards > New > New Dashboard**, y luego **Add visualization**
para cada panel. Elegir siempre el datasource **Prometheus**.

Este dashboard responde a la pregunta: *"¿el sistema operativo donde corren mis servicios
esta saludable?"*. Las metricas vienen del `prometheus.exporter.unix` que corre dentro de
Grafana Alloy (Act2-1, Paso 8), o de la historia sintetica del Paso 1 de esta guia.

> **Sobre la ventana de `rate()` (los `[20m]` en las queries de abajo):** `rate()` necesita
> al menos 2 muestras dentro de esa ventana para poder calcular algo; si la ventana es mas
> chica que el intervalo entre muestras, la query no devuelve nada. Con scraping en vivo
> (cada 15s) hasta `[1m]` funciona bien, pero si tambien cargaste el backfill de 7 dias
> (Paso 1 de esta guia — datos sinteticos cada 5 minutos), una ventana de `[1m]` o `[5m]`
> queda demasiado justa y el grafico se ve vacio salvo en los ultimos minutos reales. Por
> eso estas queries usan `[20m]` (regla practica: al menos 3-4x tu intervalo de muestreo
> mas lento). Si nunca corriste el backfill, `[5m]` tambien te sirve.

| # | Panel | Query PromQL | Tipo de panel sugerido | Para que sirve |
|---|---|---|---|---|
| 1 | CPU en uso (%) | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[20m])) * 100)` | Gauge | Detectar saturacion de CPU; sirve para dimensionar la instancia o encontrar procesos que consumen demasiado. |
| 2 | Memoria en uso (%) | `(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100` | Gauge | Detectar presion de memoria o fugas (memory leaks) antes de que el OOM killer mate un proceso. |
| 3 | Espacio en disco usado (%) | `100 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"} * 100)` | Gauge o Bar gauge (por `mountpoint`) | Anticipar que el disco se llene (logs, volumenes de Docker) y afecte a Prometheus/Grafana/la app. |
| 4 | Trafico de red (entrada/salida) | `rate(node_network_receive_bytes_total{device!="lo"}[20m])` y `rate(node_network_transmit_bytes_total{device!="lo"}[20m])` | Time series | Ver picos de trafico, detectar cuellos de botella de red o trafico anomalo. |
| 5 | Carga del sistema (load average) | `node_load1`, `node_load5`, `node_load15` | Time series | Tendencia de carga general del host; util para correlacionar con lentitud percibida en la API. |
| 6 | Tiempo activo (uptime) | `time() - node_boot_time_seconds` | Stat | Confirmar que el host no se reinicio inesperadamente (por ejemplo, tras un OOM o un crash). |
| 7 | Host disponible (up) | `up{job="prometheus"}` o el job que corresponda al exporter de Alloy | Stat (con umbral rojo/verde) | Indicador rapido de si Prometheus sigue recibiendo datos del host (Alloy activo). |

Sugerencia de organizacion: agrupar los paneles 1-3 (CPU/memoria/disco) en una fila
"Recursos", y 4-6 en una fila "Actividad", usando **Add > Row** para dividir visualmente.

## 6) Paso 4 - Dashboard "API - ServerB"

Crear un **segundo dashboard** (no agregar estos paneles al de servidores, para mantener
cada uno con un proposito claro). Este dashboard responde a la pregunta: *"¿la API esta
respondiendo bien y rapido?"*.

| # | Panel | Query PromQL | Tipo de panel sugerido | Para que sirve |
|---|---|---|---|---|
| 1 | Disponibilidad de la API | `up{job="serverB-api"}` | Stat (umbral rojo/verde) | Ver de un vistazo si Prometheus puede scrapear a ServerB ahora mismo. |
| 2 | Tasa de requests por endpoint | `sum(rate(http_requests_total[20m])) by (route)` | Time series | Ver el volumen de trafico y cuales endpoints se usan mas. |
| 3 | Tasa de errores (5xx) | `sum(rate(http_requests_total{status_code=~"5.."}[20m])) / sum(rate(http_requests_total[20m]))` | Time series (formato %) | Detectar fallas del servicio; es la metrica clasica de "error rate" en SRE. |
| 4 | Requests por codigo de estado | `sum(rate(http_requests_total[20m])) by (status_code)` | Bar chart o Time series apilado | Ver el desglose 2xx/4xx/5xx: diferenciar errores de cliente (4xx) vs errores del servidor (5xx). |
| 5 | Latencia p95 por endpoint | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[20m])) by (le, route))` | Time series | Detectar endpoints lentos; p95 importa mas que el promedio porque refleja la experiencia de los usuarios "peor servidos". |
| 6 | Latencia p99 (cola larga) | `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[20m])) by (le))` | Time series | Detectar la "cola larga" de latencia (peores casos), util para SLOs estrictos. |
| 7 | Uso de memoria del proceso Node | `process_resident_memory_bytes{job="serverB-api"}` | Time series | Detectar fugas de memoria en la app (crece sin bajar nunca). |
| 8 | CPU del proceso Node | `rate(process_cpu_user_seconds_total{job="serverB-api"}[20m])` | Time series | Ver si la API esta consumiendo CPU de forma anormal (loops, mal manejo de requests). |

> Todas estas metricas (`http_requests_total`, `http_request_duration_seconds_bucket`,
> `process_resident_memory_bytes`, `process_cpu_user_seconds_total`) ya vienen expuestas por
> ServerB en `/metrics` (ver `ServerB/src/server.js` de Act2-1): las dos primeras son
> metricas custom del negocio (requests/latencia HTTP), y las de `process_*` las agrega
> automaticamente `prom-client` (`collectDefaultMetrics`). Los endpoints `/api/error` y
> `/api/random` de ServerB (y `scripts/generate_traffic.py` en Act2-1) existen especificamente
> para que el panel de tasa de errores tenga algo que mostrar.

Sugerencia de organizacion: fila "Trafico y errores" (paneles 2-4), fila "Latencia"
(paneles 5-6), fila "Proceso" (paneles 7-8), y el panel 1 (disponibilidad) arriba de todo,
solo, como resumen ejecutivo del dashboard.

## 7) Paso 5 - Ajustes finales del dashboard

1. Nombrar cada dashboard con algo claro, ej. `Servidores - Host` y `API - ServerB`.
2. Definir el rango de tiempo por defecto (arriba a la derecha): si cargaste el backfill
   del Paso 1, usa **Last 7 days**; si no, **Last 1 hour** alcanza. Definir tambien el
   auto-refresh (ej. **10s** o **30s**) para ver los datos moverse mientras generas trafico
   de prueba:
   ```bash
   for i in $(seq 1 50); do curl -s http://localhost:8080/api/saludo > /dev/null; done
   # o, con mas variedad (incluye errores): python3 EA2/Act2-1/scripts/generate_traffic.py --duration 60 --rps 10 --error-ratio 0.15
   ```
3. (Opcional) Agregar una variable de dashboard `$route` o `$instance` (Dashboard settings
   > Variables) para poder filtrar los paneles sin editar las queries.
4. Guardar cada dashboard (icono de disquete, arriba a la derecha) con un nombre de
   carpeta comun, ej. carpeta **"Lab Monitoreo"**, para tenerlos ordenados.

> Si al abrir un dashboard ya guardado el grafico se ve vacio pese a haber corrido el
> backfill, revisa el selector de tiempo: Grafana recuerda el ultimo rango usado en la URL
> del navegador (`?from=...&to=...`), que puede pisar el default guardado del dashboard.
> Cambialo a mano a **Last 7 days** si es necesario.

## 8) Paso 6 - Exportar los dashboards a JSON (respaldo)

Un dashboard vive dentro de la base de datos de Grafana (el volumen `grafana_data` de
Act2-1). Exportarlo a JSON permite respaldarlo, versionarlo en git, o recrearlo en otra
instancia de Grafana sin rehacer los paneles a mano.

1. Abrir el dashboard que quieres respaldar.
2. Ir al menu del dashboard (icono de engranaje **Dashboard settings**, o el boton
   **Share** segun la version de Grafana).
3. Elegir **Export** (o **JSON Model**, segun la version):
   - Si aparece la opcion **"Export for sharing externally"**, actívala: esto reemplaza el
     `uid` fijo del datasource por una variable (`${DS_PROMETHEUS}`), para que el JSON se
     pueda importar en cualquier Grafana sin depender del datasource exacto de esta
     instalacion.
4. Click en **Save to file** (o copiar el contenido del JSON Model manualmente).
5. Guardar el archivo descargado en el repo, por ejemplo:
   ```
   EA2/Act2-1/ServerA/grafana/provisioning/dashboards/json/servidores-host.json
   EA2/Act2-1/ServerA/grafana/provisioning/dashboards/json/api-serverb.json
   ```
   Esa carpeta ya esta configurada como "provisioning path" en Act2-1
   (`ServerA/grafana/provisioning/dashboards/dashboards.yml`), asi que cualquier JSON que
   dejes ahi se carga **automaticamente** la proxima vez que se levante Grafana, sin volver
   a construir los paneles a mano.
6. Para restaurar el respaldo en una instalacion nueva (sin usar el provisioning
   automatico): **Dashboards > New > Import**, subir el archivo `.json` o pegar su
   contenido, elegir el datasource Prometheus cuando lo pida, y confirmar.

## 9) Checklist de verificacion

- [ ] (Opcional) `scripts/backfill_7d_history.py` corre sin errores y una query con rango
      de 7 dias (ej. `node_load1`) devuelve datos historicos.
- [ ] Data Source **Prometheus** creado (o verificado) y con **Save & test** exitoso.
- [ ] Dashboard **Servidores / Host** con al menos CPU, memoria, disco, red y uptime.
- [ ] Dashboard **API - ServerB** con disponibilidad, trafico, tasa de errores y latencia
      p95/p99.
- [ ] Ambos dashboards muestran datos reales (o historicos, si cargaste el backfill) al
      generar trafico de prueba contra ServerB.
- [ ] Con el selector de tiempo en **Last 7 days**, los graficos muestran una curva
      continua (no solo puntos sueltos al final) — si no, revisar las ventanas de `rate()`.
- [ ] Ambos dashboards exportados a `.json` y guardados en el repo (carpeta
      `ServerA/grafana/provisioning/dashboards/json/` de Act2-1).
- [ ] El JSON exportado se probo re-importandolo (via **Dashboards > Import**) para
      confirmar que funciona como respaldo real.
