# EA2 - Act 2.4: Dashboards de la comunidad de Grafana

Guia paso a paso para **buscar, descargar e implementar** dashboards publicados por la
comunidad en [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards),
sobre el stack que ya construiste en las actividades anteriores.

La idea central de la actividad es esta: importar un dashboard toma diez segundos, pero que
**muestre tus datos** es otra cosa. Vas a ver los tres desenlaces posibles, con casos
reales.

> **Depende de [EA2/Act2-1](../Act2-1) y [EA2/Act2-3](../Act2-3)**: se asume que tienes
> Prometheus y Grafana corriendo, ServerB siendo scrapeado, y Node Exporter con el job
> `node`.

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [El catalogo de la comunidad](#2-el-catalogo-de-la-comunidad)
3. [Como elegir un dashboard](#3-como-elegir-un-dashboard)
4. [Paso 1 - Importar el 1860: el que funciona](#4-paso-1---importar-el-1860-el-que-funciona)
5. [Paso 2 - Por que funciono](#5-paso-2---por-que-funciono)
6. [Paso 3 - Importar el 19062: el que engana](#6-paso-3---importar-el-19062-el-que-engana)
7. [Paso 4 - Diagnosticar el problema](#7-paso-4---diagnosticar-el-problema)
8. [Paso 5 - Adaptarlo](#8-paso-5---adaptarlo)
9. [Paso 6 - El 3662: el que ya no sirve](#9-paso-6---el-3662-el-que-ya-no-sirve)
10. [Paso 7 - Guardar lo que adaptaste](#10-paso-7---guardar-lo-que-adaptaste)
11. [Evidencias esperadas](#11-evidencias-esperadas)
12. [Troubleshooting](#12-troubleshooting)
13. [Checklist de verificacion](#13-checklist-de-verificacion)

---

## 1) Objetivo de la actividad

Que seas capaz de:

- Buscar dashboards en el catalogo de la comunidad y **evaluar si sirven** antes de
  importarlos, con criterios verificables.
- Importar un dashboard por su ID y conectarlo a tu datasource.
- Entender el papel de las **variables** de un dashboard y de que metrica dependen.
- Diagnosticar por que un dashboard importado no muestra tus datos.
- **Adaptar** las consultas de un dashboard ajeno a los labels de tu propio stack.
- Reconocer un dashboard obsoleto antes de perder tiempo con el.

## 2) El catalogo de la comunidad

En [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards) hay miles de
dashboards publicados. Cada uno tiene un **ID numerico**, que es todo lo que necesitas para
importarlo:

```
Dashboards > New > Import > pegar el ID > Load > elegir el datasource Prometheus > Import
```

No hay que descargar ningun archivo: Grafana lo baja solo. Tambien se puede bajar el JSON a
mano, que es util para inspeccionarlo antes:

```bash
curl -s https://grafana.com/api/dashboards/1860 | head -20
```

## 3) Como elegir un dashboard

Antes de importar cualquier cosa, revisa cuatro datos que estan a la vista en la pagina del
dashboard. Compara estos cuatro, que son los que vas a usar en la actividad:

| ID | Nombre | Descargas | Ultima revision | Veredicto |
|---|---|---|---|---|
| **1860** | Node Exporter Full | 145.207.454 | abril 2026 | Vigente y masivo |
| **13895** | Node Exporter Full | **334** | **febrero 2021** | Copia abandonada del anterior |
| **19062** | NodeJS Applications | 2.929 | julio 2025 | Reciente, pero hecho para Kubernetes |
| **3662** | Prometheus 2.0 Overview | 6.589.294 | **diciembre 2020** | Popular pero obsoleto |

Lo que enseña esa tabla:

- **Las descargas solas no bastan.** El 3662 tiene 6,5 millones de descargas y esta
  congelado desde 2020.
- **El nombre tampoco.** El 13895 se llama igual que el 1860 y tiene 334 descargas contra
  145 millones. No son intercambiables.
- **Lo que mas importa es para que entorno fue hecho.** El 19062 es reciente y correcto,
  pero asume Kubernetes. Sobre Docker no funciona sin retoques.

Puedes verificar estos datos por tu cuenta:

```bash
curl -s https://grafana.com/api/dashboards/1860 | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(d['name'], '| descargas:', d['downloads'], '| revision:', d['revision'], '|', d['updatedAt'][:10])"
```

## 4) Paso 1 - Importar el 1860: el que funciona

**Node Exporter Full** es el dashboard de metricas de host mas usado del mundo. Es el que
corresponde a tu ServerC de [Act2-3](../Act2-3).

1. En Grafana: **Dashboards > New > Import**.
2. Escribir `1860` en el campo de ID y presionar **Load**.
3. Elegir el datasource **Prometheus**.
4. **Import**.

Deberias ver, de inmediato, CPU por nucleo, memoria, disco, red, carga y uptime. Arriba a la
izquierda hay tres desplegables: **Job**, **Host** e **Instance**.

> Si los desplegables aparecen vacios y todos los paneles dicen "No data", no te saltes al
> troubleshooting: el Paso 2 explica exactamente por que.

## 5) Paso 2 - Por que funciono

Un dashboard de la comunidad no puede saber como se llaman tus servidores. Por eso usa
**variables**: consultas que se ejecutan contra *tu* Prometheus para llenar los
desplegables.

Las del 1860 son tres, encadenadas:

| Variable | Consulta |
|---|---|
| `$job` | `label_values(node_uname_info, job)` |
| `$nodename` | `label_values(node_uname_info{job="$job"}, nodename)` |
| `$node` | `label_values(node_uname_info{job="$job", nodename="$nodename"}, instance)` |

**Las tres dependen de una sola metrica: `node_uname_info`.** Si esa metrica no existe en tu
Prometheus, las tres variables quedan vacias y el dashboard completo queda en blanco.

Compruebalo tu mismo:

```bash
curl -s 'http://localhost:9090/api/v1/label/job/values?match[]=node_uname_info'
# {"status":"success","data":["node"]}
```

Esto es lo que ocurre en un stack como el tuyo:

```
  $job      = ['node']
  $nodename = ['ChiniyosPC']
  $node     = ['localhost:9100']
```

El dashboard funciono **porque en Act2-3 el job se llama `node` y hay un Node Exporter real
publicando `node_uname_info`**.

> **Una trampa que vale la pena conocer**: si cargaste la historia sintetica del backfill
> (Act2-1, Paso 7), esos datos **no incluyen `node_uname_info`**. Con solo backfill, el 1860
> se ve vacio aunque tengas metricas `node_*` de sobra. La metrica que llena las variables
> tiene que existir de verdad.

## 6) Paso 3 - Importar el 19062: el que engana

Ahora el dashboard de Node.js, que en teoria corresponde a tu **ServerB**.

1. **Dashboards > New > Import**, ID `19062`, **Load**.
2. Grafana pide un datasource llamado `DS_MIMIR`: eligele tu **Prometheus**. (Mimir es un
   almacenamiento compatible con Prometheus; por eso lo pide con ese nombre.)
3. **Import**.

Miralo con atencion y responde antes de seguir:

| Pregunta |
|---|
| Que muestra el desplegable de arriba? |
| Los paneles muestran datos, o dicen "No data"? |
| El panel **Process Memory Usage** muestra una linea o varias? |
| Los valores que ves, se parecen a los de tu ServerB? |

## 7) Paso 4 - Diagnosticar el problema

Este dashboard fue hecho para aplicaciones Node.js **en Kubernetes**. Su variable es:

```promql
label_values(nodejs_version_info, app_kubernetes_io_name)
```

`app_kubernetes_io_name` es un label que Kubernetes agrega a las metricas. Tu ServerB corre
en Docker, asi que ese label **no existe**:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=nodejs_version_info' | python3 -m json.tool | grep -A6 metric
```

Vas a ver los labels reales: `instance`, `job`, `major`, `minor`, `patch`, `version`. Ningun
`app_kubernetes_io_name`. Por lo tanto la variable queda **vacia**.

### Y aqui viene lo importante

Podrias esperar que, con la variable vacia, todo quede en "No data". **No es lo que pasa**, y
por eso este caso es peligroso.

Las 15 consultas del dashboard filtran asi:

```promql
process_resident_memory_bytes{app_kubernetes_io_name=~"$instance"}
```

Con `$instance` vacia, eso queda en `=~""`. Y en PromQL, **una expresion regular vacia
coincide con las series que NO tienen ese label**. Resultado:

```
process_resident_memory_bytes{app_kubernetes_io_name=~""}  ->  3 series:
   job=serverB-api    59.3 MB
   job=node           21.8 MB
   job=prometheus     99.2 MB
```

El panel **muestra datos**: los de ServerB, los del Node Exporter y los del propio
Prometheus, todos mezclados en el mismo grafico. Parece que funciona, y esta mal. Un
dashboard vacio te avisa que algo falla; uno que muestra datos equivocados, no.

> Las 15 consultas del dashboard dependen de ese label. No es que falle un panel: falla
> entero.

### Un segundo hallazgo

Revisa la lista de paneles del 19062: **no tiene ni un panel de HTTP**. No hay requests por
segundo, ni codigos de respuesta, ni latencia. Solo memoria, heap, event loop y handles del
proceso.

O sea que, aunque lo adaptes perfecto, **no te sirve para monitorear tu API** como servicio.
Para eso necesitas `http_requests_total` y `http_request_duration_seconds`, que ServerB
expone y este dashboard nunca consulta. Elegir un dashboard tambien es revisar que mide.

## 8) Paso 5 - Adaptarlo

El arreglo es mecanico: reemplazar el label de Kubernetes por el que si tienes.

### En la interfaz de Grafana

1. **Dashboard settings** (engranaje) > **Variables** > `instance`.
2. Cambiar la consulta a:
   ```promql
   label_values(nodejs_version_info, job)
   ```
3. Guardar y volver al dashboard: el desplegable ahora muestra `serverB-api`.
4. Editar cada panel y cambiar `app_kubernetes_io_name` por `job` en la consulta.

### O de una vez, sobre el JSON

Mas rapido para los 15 paneles. Bajas el dashboard, lo editas y lo importas:

```bash
# 1. Bajar el JSON de la revision actual
curl -s https://grafana.com/api/dashboards/19062 \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['revision'])"
curl -s https://grafana.com/api/dashboards/19062/revisions/7/download -o 19062.json

# 2. Cambiar el label de Kubernetes por el job
sed -i 's/app_kubernetes_io_name/job/g' 19062.json

# 3. Importar: Dashboards > New > Import > Upload dashboard JSON file
```

Verifica que quedo bien:

```bash
curl -s 'http://localhost:9090/api/v1/label/job/values?match[]=nodejs_version_info'
# {"status":"success","data":["serverB-api"]}
```

Con eso los paneles pasan a mostrar solo tu ServerB:

```
  process_resident_memory_bytes{job=~"serverB-api"}   ->  1 serie
  nodejs_eventloop_lag_seconds{job=~"serverB-api"}    ->  1 serie
  nodejs_active_handles_total{job=~"serverB-api"}     ->  1 serie
```

> Fijate en lo que acabas de hacer: tomaste un dashboard ajeno, encontraste el supuesto que
> no se cumplia en tu entorno, y lo corregiste. Eso es el trabajo real con dashboards de la
> comunidad; importarlos es la parte facil.

## 9) Paso 6 - El 3662: el que ya no sirve

Importa tambien `3662` (**Prometheus 2.0 Overview**) y observa que pasa. Es un dashboard con
6,5 millones de descargas.

Antes de importarlo, mira su ficha tecnica:

```bash
curl -s https://grafana.com/api/dashboards/3662/revisions/2/download | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('schemaVersion:', d['schemaVersion'])
print('requiere Grafana:', [r['version'] for r in d.get('__requires',[]) if r['id']=='grafana'])
print('paneles en la raiz:', len([p for p in d.get('panels',[])]))"
```

Resultado:

```
schemaVersion: 14
requiere Grafana: ['4.5.0-beta1']
paneles en la raiz: 0
```

Tres senales de alarma juntas:

- **`schemaVersion: 14`**: los dashboards actuales usan la 41. Esta es de 2017.
- **Requiere Grafana 4.5.0-beta1**: tu Grafana es la 12 o 13.
- **Cero paneles en la raiz**: usa la estructura `rows` anterior a Grafana 5. Grafana lo
  migra al importarlo, pero la conversion no siempre sale limpia.

Grafana lo va a importar igual. Anota que paneles quedan funcionando y cuales no, y por que.

> Moraleja: `updatedAt` y `schemaVersion` dicen mas sobre si un dashboard te va a servir que
> el numero de descargas.

## 10) Paso 7 - Guardar lo que adaptaste

Un dashboard adaptado que vive solo dentro de Grafana se pierde cuando el contenedor se
recrea. Exportalo:

1. Abrir el dashboard adaptado > **Export** > **Save to file**.
2. Guardarlo en la carpeta de provisioning de Act2-1:
   ```
   EA2/Act2-1/ServerA/grafana/provisioning/dashboards/json/
   ```
3. Reiniciar Grafana: `docker compose restart grafana` en ServerA.

Cualquier JSON que dejes en esa carpeta se carga solo al levantar el stack.

> **Sobre el datasource**: el `datasource.yml` de Act2-1 define `uid: prometheus`, un valor
> fijo. Eso es lo que permite que un dashboard exportado funcione en otra instalacion del
> laboratorio. Si el uid fuera aleatorio, el JSON exportado apuntaria a un datasource que en
> otra maquina no existe, y todos los paneles darian "Datasource not found".

## 11) Evidencias esperadas

1. Captura del **1860** funcionando, con los tres desplegables llenos.
2. La salida de `label_values(node_uname_info, job)` en tu entorno.
3. Captura del **19062 recien importado**, mostrando el problema (desplegable vacio y el
   panel de memoria con varias lineas mezcladas).
4. Explicacion escrita de **por que** los paneles muestran datos en vez de quedar vacios.
5. Captura del **19062 adaptado**, con el desplegable mostrando `serverB-api`.
6. Lista de que **no** puede monitorear el 19062 aunque este adaptado, y que metricas de
   ServerB harian falta.
7. Captura del **3662** importado, indicando que paneles sobrevivieron a la migracion.
8. El JSON del dashboard adaptado, guardado en la carpeta de provisioning.

## 12) Troubleshooting

| Sintoma | Causa | Solucion |
|---|---|---|
| Todos los paneles dicen "No data" y los desplegables estan vacios | La metrica que llena las variables no existe en tu Prometheus | Identificar de que metrica depende la variable (Paso 2) y verificar que exista |
| El dashboard pide un datasource con un nombre raro (`DS_MIMIR`, `DS_THEMIS`) | Fue exportado desde una instalacion con otro datasource | Elegir tu **Prometheus** en ese campo al importar |
| Los paneles muestran datos, pero mezclados o que no corresponden | Una variable vacia con `=~""` esta dejando pasar todas las series sin ese label | Adaptar el label al de tu stack (Paso 5) |
| "Dashboard not found" al importar por ID | El ID no existe o esta mal escrito | Verificar con `curl -s https://grafana.com/api/dashboards/<ID>` |
| El dashboard se ve descuadrado o con paneles vacios tras importar | `schemaVersion` muy antigua, migrada por Grafana | Ver el Paso 6: probablemente convenga buscar otro dashboard |
| Importa bien pero al reiniciar Grafana desaparece | Se guardo solo en la base de datos de Grafana, sin volumen ni provisioning | Exportarlo a JSON y dejarlo en la carpeta de provisioning (Paso 7) |
| "Datasource not found" al importar un JSON propio | El JSON referencia un uid de datasource que no existe en esta Grafana | Revisar que el datasource tenga `uid: prometheus` (Paso 7) |

## 13) Checklist de verificacion

- [ ] Verificados con la API de grafana.com los datos de los cuatro dashboards de la tabla.
- [ ] **1860** importado y mostrando datos, con los tres desplegables llenos.
- [ ] Identificada la metrica de la que dependen sus variables, y comprobado que existe.
- [ ] **19062** importado sin adaptar, con el problema documentado.
- [ ] Explicado por que `=~""` hace que los paneles muestren datos equivocados.
- [ ] **19062 adaptado**, con el desplegable mostrando `serverB-api` y una sola serie por panel.
- [ ] Documentado que metricas de ServerB no cubre ese dashboard.
- [ ] **3662** importado, con las tres senales de obsolescencia identificadas.
- [ ] Dashboard adaptado exportado a JSON y dejado en la carpeta de provisioning.
- [ ] Grafana reiniciada y el dashboard adaptado cargandose solo.
