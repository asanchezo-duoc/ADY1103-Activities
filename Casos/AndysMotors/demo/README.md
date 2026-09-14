# Entorno de demostración de Andys Motors

La plataforma del [caso Andys Motors](../README.md) desplegada como software real:
seis aplicaciones instrumentadas, una base de datos, un balanceador de entrada, tráfico
que sigue la curva horaria del negocio y escenarios de falla que se encienden y apagan en
caliente.

> **Aquí no hay Prometheus ni Grafana, a propósito.** Este es el entorno que hay que
> observar; el stack de monitoreo lo construye cada estudiante. Lo único que el entorno
> ofrece es telemetría expuesta: `/metrics` en cada plataforma, logs estructurados en
> stdout, y las métricas del balanceador.

## Índice

1. [Qué levanta](#1-qué-levanta)
2. [Levantarlo en una máquina](#2-levantarlo-en-una-máquina)
3. [Levantarlo en seis servidores](#3-levantarlo-en-seis-servidores)
4. [Qué telemetría expone](#4-qué-telemetría-expone)
5. [Generar tráfico](#5-generar-tráfico)
6. [Escenarios de falla](#6-escenarios-de-falla)
7. [El punto ciego del caso, comprobado](#7-el-punto-ciego-del-caso-comprobado)
8. [Endpoints disponibles](#8-endpoints-disponibles)
9. [Troubleshooting](#9-troubleshooting)
10. [Apagar](#10-apagar)

---

## 1) Qué levanta

| Plataforma del caso | Servicio | Puerto | Depende de |
|---|---|---|---|
| Sitio web público | `web-api` | 8081 | stock, agenda, crm |
| Consulta de stock | `stock-api` | 8082 | base de datos |
| Agendamiento de visitas | `agenda-api` | 8083 | base de datos |
| CRM / ventas | `crm-api` | 8084 | base de datos |
| Sistema de pagos | `pagos-api` | 8085 | gateway, base de datos |
| Proveedor externo de pagos | `gateway-externo` | 8086 | — |
| Base de datos central | `postgres` | 5432 | — |
| Entrada pública | `haproxy` | 80 y 8404 | todas |

Las seis aplicaciones son **la misma imagen**: cambia solo la variable de entorno
`SERVICIO`. Se construye una vez y se despliega con distinta configuración en cada
servidor.

HAProxy es la puerta de entrada: enruta por prefijo de ruta hacia cada plataforma, así que
los backends no necesitan exponerse a Internet.

## 2) Levantarlo en una máquina

Para probar en el computador propio, o para tener todo el caso en una sola instancia:

```bash
cd Casos/AndysMotors/demo

cp .env.example .env
# editar .env: cambiar DB_PASSWORD y ANDYS_ADMIN_TOKEN

docker build -t andys-motors:local ./app
docker compose --profile todo up -d
docker compose --profile todo ps
```

Verificar:

```bash
curl -s http://localhost/                                   # sitio público
curl -s http://localhost/stock/api/stock | head -c 200      # stock, vía el balanceador
curl -s http://localhost:8404/metrics | grep -c '^# TYPE'   # métricas del balanceador
```

> Si la máquina ya tiene un PostgreSQL escuchando en el 5432, agrega
> `DB_PUBLISH_PORT=5433` al `.env`.

## 3) Levantarlo en seis servidores

Es el despliegue que corresponde al caso: cada plataforma en su propia máquina.

En **cada** servidor se copia esta misma carpeta, se ajusta el `.env` con las IP privadas
de las plataformas de las que ese servidor depende, y se levanta solo su perfil:

| Servidor | Comando | Necesita en su `.env` |
|---|---|---|
| ServerData | `docker compose --profile data up -d` | — |
| ServerStock | `docker compose --profile stock up -d` | `DB_HOST` |
| ServerAgenda | `docker compose --profile agenda up -d` | `DB_HOST` |
| ServerCRM | `docker compose --profile crm up -d` | `DB_HOST` |
| ServerPagos | `docker compose --profile pagos up -d` | `DB_HOST` |
| ServerWeb | `docker compose --profile web up -d` | `STOCK_HOST`, `AGENDA_HOST`, `CRM_HOST` |
| ServerBorde | `docker compose --profile borde up -d` | las cinco direcciones |

En los servidores que corren aplicaciones hay que construir la imagen primero
(`docker build -t andys-motors:local ./app`); ServerData y ServerBorde usan imágenes
oficiales y no la necesitan.

Se usan **IP privadas** a propósito: en AWS se conservan cuando la instancia se detiene y
se vuelve a encender, mientras que las públicas cambian.

> Cada plataforma usa el mismo número de puerto dentro y fuera del contenedor, para que la
> dirección sea idéntica en los dos modos de despliegue.

## 4) Qué telemetría expone

### 4.1 Métricas técnicas (las tiene toda plataforma)

| Métrica | Tipo | Para qué |
|---|---|---|
| `http_requests_total{method,route,status_code}` | counter | Tasa de peticiones y de errores |
| `http_request_duration_seconds` | histogram | Latencia, incluidos percentiles con `histogram_quantile()` |
| `dependencia_request_duration_seconds{destino,operacion,resultado}` | histogram | Cuánto tarda cada llamada a **otra** plataforma |
| `andys_servicio_info{version,plataforma}` | gauge | Métrica de tipo info: el valor siempre es 1, el dato está en los labels |
| `nodejs_*`, `process_*` | varias | CPU, memoria y event loop del proceso |

Todas las series llevan el label `servicio`, así que se pueden agrupar por plataforma con
`by (servicio)`.

`dependencia_request_duration_seconds` es la que responde la pregunta más frecuente de un
incidente: **¿estoy lento yo, o está lento aquel de quien dependo?**

### 4.2 Métricas de negocio (solo las puede emitir la aplicación)

| Plataforma | Métrica | Qué mide |
|---|---|---|
| web | `solicitudes_contacto_total{resultado}` | Solicitudes de contacto del sitio |
| web | `visitas_agendadas_sitio_total{resultado}` | Agendamientos iniciados desde el sitio |
| stock | `consultas_stock_total{resultado,sucursal}` | Consultas de disponibilidad |
| stock | `vehiculos_disponibles{sucursal,condicion}` | Inventario actual |
| **agenda** | **`agendamientos_solicitados_total{sucursal}`** | Visitas que los clientes pidieron |
| **agenda** | **`agendamientos_confirmados_total{sucursal}`** | Visitas que realmente quedaron registradas |
| crm | `clientes_registrados_total{origen}` | Altas de clientes |
| crm | `oportunidades_creadas_total` | Oportunidades comerciales abiertas |
| crm | `oportunidades_vinculadas_total` | Oportunidades correctamente asociadas a un cliente |
| crm | `ventas_cerradas_total{sucursal}`, `monto_vendido_clp_total{sucursal}` | Ventas y monto |
| pagos | `pagos_total{resultado}`, `monto_transado_clp_total` | Pagos por resultado y monto aprobado |
| gateway | `autorizaciones_total{resultado}` | Respuestas del proveedor externo |

**Los dos pares en negrita son la clave del caso.** La distancia entre "solicitados" y
"confirmados", o entre "creadas" y "vinculadas", es la única señal de que el negocio se
rompió. Ninguna métrica de infraestructura la puede ver.

### 4.3 Métricas del balanceador

HAProxy 3.0 trae el exporter de Prometheus integrado: **204 familias de métricas** en
`http://<ServerBorde>:8404/metrics`, sin instalar nada. Las más útiles:

| Métrica | Para qué |
|---|---|
| `haproxy_server_status{proxy,server,state}` | Si cada plataforma está UP o DOWN |
| `haproxy_backend_http_responses_total{proxy,code}` | Desglose 2xx/4xx/5xx por plataforma |
| `haproxy_backend_response_time_average_seconds` | Latencia promedio por plataforma |
| `haproxy_frontend_current_sessions` | Concurrencia en la entrada |

> **Limitación importante**: `haproxy_backend_response_time_average_seconds` es un
> **promedio de las últimas 1024 conexiones**, no un histograma. No se puede calcular un
> percentil 95 desde el balanceador. Para eso hay que usar
> `http_request_duration_seconds` de las propias aplicaciones. Es un buen ejemplo de por
> qué la telemetría del borde no reemplaza a la de la aplicación.

También hay una página de estado legible en `http://<ServerBorde>:8404/stats`.

### 4.4 Logs

Cada aplicación escribe **una línea JSON por evento** a stdout:

```json
{"ts":"2026-09-14T02:15:12.774Z","nivel":"info","servicio":"agenda","mensaje":"peticion atendida","metodo":"POST","ruta":"/api/agendamientos","status":201,"duracion_ms":4,"request_id":"922911fc-..."}
```

El `request_id` se propaga entre plataformas: HAProxy lo crea si no viene, y cada servicio
lo pasa a las llamadas que hace. Una misma transacción deja **el mismo id** en los logs del
balanceador, del sitio web, del CRM y de la base de datos. Es una traza pobre, pero permite
reconstruir el recorrido completo de una petición.

```bash
docker compose logs -f agenda-api | grep '"nivel":"warn"'
```

### 4.5 Lo que el entorno NO expone

Deliberadamente faltan, porque instalarlos es parte del trabajo:

- Métricas del sistema operativo de cada servidor → hay que desplegar **Node Exporter**.
- Métricas de PostgreSQL → hay que desplegar **postgres-exporter**.
- Cualquier forma de almacenamiento, consulta o visualización → **Prometheus y Grafana**.

## 5) Generar tráfico

Sin tráfico los gráficos son líneas planas, y sin variación horaria no se puede justificar
un SLA distinto por franja ni analizar el presupuesto de error.

El generador sigue la curva del caso: tráfico alto entre 09:00 y 19:00, prácticamente nulo
entre 02:00 y 06:00, con la rampa progresiva de las 06:00 a las 09:00. Los sistemas
internos (CRM y pagos) solo tienen actividad en horario comercial.

```bash
# Un día completo en 24 minutos (1 minuto real = 1 hora simulada)
./scripts/generar_trafico.py --url http://<ServerBorde> --hora-inicio 0 --duracion 1440

# Media hora de tráfico en horario comercial, a ritmo real
./scripts/generar_trafico.py --url http://<ServerBorde> --hora-inicio 10 --factor 1 --duracion 1800

./scripts/generar_trafico.py --help
```

Solo usa la librería estándar de Python 3.

## 6) Escenarios de falla

```bash
./scripts/escenario.sh listar
./scripts/escenario.sh activar    agenda_silenciosa
./scripts/escenario.sh desactivar agenda_silenciosa
./scripts/escenario.sh apagar-todo
```

| Escenario | Qué provoca | Qué lo delata |
|---|---|---|
| `agenda_silenciosa` | El agendamiento responde 201, rápido y sin errores, pero no persiste nada | Solo la brecha entre `agendamientos_solicitados_total` y `agendamientos_confirmados_total` |
| `crm_huerfano` | El cliente se registra, pero la oportunidad queda sin vincular | La brecha entre `oportunidades_creadas_total` y `oportunidades_vinculadas_total` |
| `stock_desactualizado` | El stock responde datos antiguos: se ofrecen vehículos que ya no están | Nada técnico. Solo se nota comparando con la base de datos |
| `gateway_lento` | El proveedor externo tarda entre 3 y 8 segundos | Latencia de pagos, y sobre todo `dependencia_request_duration_seconds` |
| `gateway_rechazos` | El proveedor rechaza cerca de la mitad de las autorizaciones | `pagos_total{resultado="rechazado"}` |
| `db_lenta` | Cada consulta a la base suma entre 300 y 900 ms | Latencia en las cuatro plataformas que usan la base |

En el despliegue de seis servidores hay que indicar dónde vive cada plataforma:

```bash
export STOCK_ADDR=10.0.1.11 AGENDA_ADDR=10.0.1.12 CRM_ADDR=10.0.1.13
export PAGOS_ADDR=10.0.1.14 GATEWAY_ADDR=10.0.1.14
./scripts/escenario.sh activar agenda_silenciosa
```

El panel está protegido por el token de `ANDYS_ADMIN_TOKEN`. Sin él responde 401.

## 7) El punto ciego del caso, comprobado

Esta es la secuencia que demuestra el problema central del caso. Son treinta agendamientos:
quince con el sistema sano y quince con la falla activa.

```bash
./scripts/escenario.sh activar agenda_silenciosa

for i in $(seq 1 15); do
  curl -s -o /dev/null -X POST http://<ServerBorde>/api/agendar \
    -H 'Content-Type: application/json' \
    -d "{\"nombre\":\"Cliente $i\",\"sucursal\":\"Providencia\",\"fecha_visita\":\"2026-10-15\"}"
done

curl -s http://<ServerAgenda>:8083/metrics | grep -E '^agendamientos_(solicitados|confirmados)_total'
curl -s http://<ServerBorde>:8404/metrics | grep 'code="5xx"'
```

Resultado medido en este entorno:

| Señal | Antes | Después |
|---|---|---|
| `agendamientos_solicitados_total` | 16 | **31** |
| `agendamientos_confirmados_total` | 16 | **16** |
| Filas reales en la base de datos | 16 | **16** |
| Respuestas 5xx en HAProxy | 0 | **0** |
| Estado del backend en HAProxy | UP | **UP** |
| Código y latencia de la respuesta | 201 en 3 ms | **201 en 3 ms** |

Infraestructura impecable, negocio roto a la mitad. Es exactamente lo que reportan los
vendedores en el caso, y la razón por la que CloudWatch mirando EC2 y RDS no alcanza.

## 8) Endpoints disponibles

| Método y ruta (por el balanceador) | Plataforma | Qué hace |
|---|---|---|
| `GET /` | web | Portada del sitio |
| `GET /api/catalogo` | web → stock | Catálogo de vehículos |
| `POST /api/contacto` | web → crm | Solicitud de contacto: crea cliente y oportunidad |
| `POST /api/agendar` | web → agenda | Agenda una visita |
| `GET /stock/api/stock` | stock | Stock disponible, filtrable por `?sucursal=` |
| `GET /crm/api/oportunidades` | crm | Oportunidades, con su cliente asociado |
| `POST /crm/api/clientes` | crm | Alta de cliente |
| `POST /crm/api/ventas` | crm | Cierre de venta |
| `POST /pagos/api/pagos` | pagos → gateway | Procesa un pago |
| `GET /agenda/api/agendamientos` | agenda | Agendamientos registrados |

Y en cada plataforma, directamente en su puerto: `GET /health`, `GET /metrics`,
`GET|POST /admin/fallas`.

## 9) Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| `image "andys-motors:local": already exists` | Se intentó construir la imagen desde Compose | Construir aparte: `docker build -t andys-motors:local ./app` |
| El puerto 5432 ya está en uso | La máquina tiene su propio PostgreSQL | Agregar `DB_PUBLISH_PORT=5433` al `.env` |
| Un backend sale DOWN en `:8404/stats` | Esa plataforma no arrancó, o la dirección del `.env` está mal | `docker compose logs <servicio>`, y revisar la IP privada |
| HAProxy arranca pero todo devuelve 503 | Los backends aún no están listos | HAProxy los reincorpora solo en cuanto pasan el health check |
| Una aplicación reintenta y no arranca | La base de datos todavía no está disponible | Es el comportamiento esperado: reintenta 30 veces cada 2 segundos |
| `/admin/fallas` devuelve 401 | Falta la cabecera del token, o no coincide | Exportar `ANDYS_ADMIN_TOKEN` con el valor del `.env` |
| El generador de tráfico no dispara nada | La hora simulada está en la madrugada | Es correcto: entre 02:00 y 06:00 el tráfico es casi nulo. Usar `--hora-inicio 10` |

## 10) Apagar

```bash
docker compose --profile todo down          # conserva los datos
docker compose --profile todo down -v       # borra también la base de datos
```

En el despliegue de seis servidores, en cada uno: `docker compose --profile <suyo> down`.
