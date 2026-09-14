# ADY1103-Activities

Este repositorio reúne las actividades diseñadas por **Andrés Sánchez** para la asignatura
**Monitoreo y Observabilidad**.

Cada actividad vive en su propia carpeta, organizada por unidad/evaluación:

| Carpeta | Actividad |
|---|---|
| [`EA2/Act2-1`](./EA2/Act2-1) | Monitoreo con Prometheus, Grafana y Grafana Alloy: stack de observabilidad (ServerA) sobre una API de ejemplo (ServerB), con monitoreo opcional del host. |
| [`EA2/Act2-2`](./EA2/Act2-2) | Dashboards de Grafana: data source de Prometheus, dashboard de servidores y dashboard de la API (ServerB), carga de historia sintetica y exportacion a JSON. |
| [`EA2/Act2-3`](./EA2/Act2-3) | ServerC, Node Exporter y PromQL en profundidad: nuevo servidor observado por pull, catalogo de metricas del sistema operativo, exploracion con Grafana Explore, funciones de tasa y agregacion. |
| [`EA3/Act3-1`](./EA3/Act3-1) | Aprovisionamiento de la plataforma del caso Andys Motors en AWS con Terraform y Docker: infraestructura como codigo, ciclo plan/apply/destroy y contraste entre CloudWatch y un stack de observabilidad propio. |

Cada carpeta de actividad incluye su propio `README.md` con la guía paso a paso para
desarrollarla.

## Casos

Además, la carpeta [`Casos`](./Casos) reúne los casos de estudio de empresas ficticias que
se usan como contexto de negocio en la asignatura:

| Caso | Rubro |
|---|---|
| [`Casos/AndysMotors`](./Casos/AndysMotors) | Comercialización presencial de vehículos nuevos y usados, con plataformas desplegadas sobre AWS. |
