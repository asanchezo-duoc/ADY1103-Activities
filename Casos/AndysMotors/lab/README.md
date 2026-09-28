# Laboratorio local sin Terraform

Este laboratorio reproduce la topología distribuida del caso usando Docker
Compose independientes. No requiere AWS ni Terraform.

## Requisitos

- Docker Desktop o Docker Engine con Docker Compose v2.
- Puertos libres: `80`, `5433`, `8081` a `8086` y `8404`.
- Al menos 4 GB de memoria disponible para Docker.

## Orden de arranque

Desde cada carpeta, ejecutar `docker compose up -d`:

1. `servidores/data`
2. `servidores/stock`, `servidores/agenda`, `servidores/crm` y `servidores/pagos`
3. `servidores/web`
4. `servidores/borde`

La imagen común se construye una sola vez desde `demo/`:

```bash
docker build -t andys-motors:local demo/app
```

Después de construir la imagen, levantar los Compose en este orden:

```bash
docker compose -f servidores/data/docker-compose.yml up -d
docker compose -f servidores/stock/docker-compose.yml up -d
docker compose -f servidores/agenda/docker-compose.yml up -d
docker compose -f servidores/crm/docker-compose.yml up -d
docker compose -f servidores/pagos/docker-compose.yml up -d
docker compose -f servidores/web/docker-compose.yml up -d
docker compose -f servidores/borde/docker-compose.yml up -d
```

Los servicios quedan publicados en los mismos puertos del caso: web `8081`,
stock `8082`, agenda `8083`, CRM `8084`, pagos `8085`, gateway `8086`,
PostgreSQL `5433` y HAProxy `80`/`8404`. El puerto `5433` evita interferir con
un PostgreSQL local que pueda existir en el PC.

Prometheus, Grafana, sus archivos de configuración, las consultas PromQL y los
dashboards **no forman parte del laboratorio entregado**. Son responsabilidad
de cada estudiante según la evaluación.

Cada Compose es deliberadamente independiente y usa `host.docker.internal` para
comunicarse con los otros servidores. En Linux se agrega automáticamente el
alias mediante `host-gateway`.

## Accesos

- Sitio público: <http://localhost>
- Stock: <http://localhost:8082>
- Agenda: <http://localhost:8083>
- CRM: <http://localhost:8084>
- Pagos: <http://localhost:8085>
La web pública incluye catálogo, formulario de contacto y enlaces al portal de
empleados. Cada plataforma interna muestra una interfaz operativa conectada a
su API real. Los alumnos deben instalar su propio stack de observabilidad y
conectarlo a los endpoints `/metrics`.

## Prueba rápida

```bash
curl http://localhost/health
curl http://localhost/api/catalogo
curl http://localhost:8084/health
```

PostgreSQL crea las tablas y carga vehículos de ejemplo desde
`servidores/data/init/001-andysmotors.sql`. Los datos quedan en el volumen
`andys-data-postgres`.

Para detener todo, ejecutar `docker compose down` en cada carpeta. Los datos de
PostgreSQL quedan en el volumen `andys-data-postgres`.

Para detener todos los servidores:

```bash
for servidor in data stock agenda crm pagos web borde; do
  docker compose -f "servidores/$servidor/docker-compose.yml" down
done
```

Para reiniciar la base desde cero, eliminar el volumen con
`docker volume rm andys-data-postgres`.

## Solución de problemas

- Revisar estado: `docker ps --filter name=andys-server`.
- Revisar logs: `docker compose -f servidores/crm/docker-compose.yml logs -f`.
- Si aparece `503`, esperar unos segundos y verificar que las APIs estén arriba.
- Si `5433` está ocupado, cambiarlo en el Compose de `data` y en `DB_PORT` de
  `stock`, `agenda`, `crm`, `pagos` y `web`.

Este laboratorio es paralelo a `../infra/`: simula localmente la topología que
Terraform despliega en AWS, sin requerir credenciales ni una cuenta cloud. Su
objetivo es entregar un ambiente funcional y reproducible; la solución de
observabilidad evaluada debe ser construida por los estudiantes.
