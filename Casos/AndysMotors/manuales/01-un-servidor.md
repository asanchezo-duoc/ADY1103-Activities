# Manual 1: Andys Motors en un solo servidor

Guía manual, comando por comando, para levantar el [entorno de demostración](../demo) completo
en **una sola instancia EC2** del Learner Lab: las seis plataformas, la base de datos y el
balanceador HAProxy.

Es la opción recomendada para la Evaluación Parcial 3: una sola máquina, un solo CloudWatch
Agent y todos los logs en la misma carpeta. Si necesitas cada plataforma en su propio servidor,
usa el [Manual 2](./02-varios-servidores.md).

> Todo esto lo hace también el código Terraform de [`infra/`](../infra) de forma automática.
> Aquí se hace a mano para entender cada paso.

## Índice

1. [Qué vas a tener al final](#1-qué-vas-a-tener-al-final)
2. [Paso 1 - Crear la instancia](#2-paso-1---crear-la-instancia)
3. [Paso 2 - Conectarse](#3-paso-2---conectarse)
4. [Paso 3 - Instalar Docker y Git](#4-paso-3---instalar-docker-y-git)
5. [Paso 4 - Clonar el repositorio](#5-paso-4---clonar-el-repositorio)
6. [Paso 5 - Configurar el .env](#6-paso-5---configurar-el-env)
7. [Paso 6 - Construir la imagen](#7-paso-6---construir-la-imagen)
8. [Paso 7 - Levantar el entorno](#8-paso-7---levantar-el-entorno)
9. [Paso 8 - Verificar](#9-paso-8---verificar)
10. [Paso 9 - Generar tráfico y fallas](#10-paso-9---generar-tráfico-y-fallas)
11. [Al volver a una sesión del lab](#11-al-volver-a-una-sesión-del-lab)
12. [Actualizar el entorno](#12-actualizar-el-entorno)
13. [Apagar](#13-apagar)
14. [Troubleshooting](#14-troubleshooting)

---

## 1) Qué vas a tener al final

```
                        EC2 (una sola instancia)
Internet --:80-->  +----------------------------------------------+
                   |  haproxy :80 :8404                            |
                   |    -> web :8081 -> stock :8082               |
                   |                 -> agenda :8083              |
                   |                 -> crm :8084                 |
                   |    -> pagos :8085 -> gateway :8086           |
                   |  postgres :5432                              |
                   |                                              |
                   |  /var/log/andysmotors/<plataforma>.log       |
                   +----------------------------------------------+
```

Cada plataforma escribe sus logs en `/var/log/andysmotors/` del servidor, listos para el
CloudWatch Agent.

## 2) Paso 1 - Crear la instancia

**EC2** > **Lanzar instancias**:

| Campo | Valor |
|---|---|
| Nombre | `andys-motors` |
| AMI | **Amazon Linux 2023** (recomendada) o **Red Hat**, ver el paso 3 |
| Tipo de instancia | `t3.small` (2 GB de RAM). Con `t3.micro` la RAM queda muy justa para ocho contenedores |
| Par de claves | `vockey` |
| Red | VPC por defecto |
| Grupo de seguridad | Crear uno nuevo, `andys-motors-sg`, con las reglas de abajo |
| Almacenamiento | 20 GiB |
| Detalles avanzados > Perfil de instancia de IAM | `LabInstanceProfile` (lo necesitará el CloudWatch Agent) |

Reglas de entrada del grupo de seguridad:

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | `0.0.0.0/0` | Conectarse (EC2 Instance Connect necesita este origen) |
| HTTP | 80 | `0.0.0.0/0` | Sitio público de Andys Motors |
| TCP personalizado | 8404 | Mi IP | Página de estado y métricas de HAProxy |
| TCP personalizado | 8081-8086 | Mi IP | Opcional: portales internos y `/metrics` de cada plataforma desde tu PC |

## 3) Paso 2 - Conectarse

- **Amazon Linux 2023**: EC2 > tu instancia > **Conectar** > **Conexión de la instancia EC2** >
  usuario `ec2-user`.
- **Red Hat**: no trae EC2 Instance Connect. Entra desde la terminal del Learner Lab con la llave
  (o instala Instance Connect como en [Act3-3](../../../EA3/Act3-3)):

```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP_PUBLICA>
```

## 4) Paso 3 - Instalar Docker y Git

### Si elegiste Amazon Linux 2023

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# Amazon Linux no trae el plugin de Compose: se descarga el binario oficial
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -fsSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

### Si elegiste Red Hat

```bash
sudo dnf install -y dnf-plugins-core git
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

### En ambos casos

El permiso para usar Docker sin `sudo` se aplica al volver a entrar. **Cierra la sesión
(`exit`) y vuelve a conectarte**, y verifica:

```bash
docker version --format '{{.Server.Version}}'
docker compose version
```

## 5) Paso 4 - Clonar el repositorio

```bash
cd ~
git clone https://github.com/asanchezo-duoc/ADY1103-Activities.git
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
```

Desde aquí, **todos los comandos se ejecutan dentro de `demo/`**.

## 6) Paso 5 - Configurar el .env

```bash
cp .env.example .env

# Cambia la contraseña de la base de datos (usa una propia)
sed -i 's/^DB_PASSWORD=.*/DB_PASSWORD=Andys.Lab_2026/' .env

# Token para encender y apagar escenarios de falla
sed -i 's/^ANDYS_ADMIN_TOKEN=.*/ANDYS_ADMIN_TOKEN=andys-lab/' .env

grep -E '^(DB_PASSWORD|ANDYS_ADMIN_TOKEN)=' .env
```

En un solo servidor **no hay que configurar direcciones**: las plataformas se encuentran por el
nombre de su contenedor dentro de la red de Docker.

## 7) Paso 6 - Construir la imagen

Las seis plataformas usan la misma imagen; cambia solo la variable `SERVICIO`. Se construye una
vez:

```bash
docker build -t andys-motors:local ./app
```

Tarda un par de minutos la primera vez (descarga `node:20-alpine` e instala dependencias).

## 8) Paso 7 - Levantar el entorno

```bash
docker compose --profile todo up -d
docker compose --profile todo ps
```

Los ocho contenedores deben quedar `running`, y las seis plataformas en `healthy` después de
unos 30 segundos. Si alguna aparece reiniciándose al principio, es normal: espera a que
PostgreSQL esté listo y reintenta sola.

## 9) Paso 8 - Verificar

```bash
# Sitio público, a través del balanceador
curl -s http://localhost/ | head -c 200; echo

# Catálogo: el sitio le pide los datos a stock
curl -s http://localhost/api/catalogo | head -c 200; echo

# Salud de cada plataforma
for p in 8081 8082 8083 8084 8085 8086; do echo -n "$p: "; curl -s http://localhost:$p/health; echo; done

# Métricas Prometheus del balanceador
curl -s http://localhost:8404/metrics | grep -c '^# TYPE'

# Logs en archivos, listos para el CloudWatch Agent
ls -l /var/log/andysmotors/
tail -n 2 /var/log/andysmotors/web.log
```

Desde tu navegador: `http://<IP_PUBLICA>` (sitio público) y `http://<IP_PUBLICA>:8404/stats`
(estado de HAProxy).

## 10) Paso 9 - Generar tráfico y fallas

Tráfico de horario comercial durante 30 minutos. Déjalo corriendo en una terminal aparte (abre
una segunda conexión a la instancia):

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
python3 scripts/generar_trafico.py --url http://localhost --hora-inicio 9 --factor 1 --duracion 1800
```

Escenarios de falla, desde la otra terminal:

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
export ANDYS_ADMIN_TOKEN=andys-lab     # el mismo valor del .env

./scripts/escenario.sh listar
./scripts/escenario.sh activar    agenda_silenciosa
./scripts/escenario.sh desactivar agenda_silenciosa
./scripts/escenario.sh apagar-todo
```

## 11) Al volver a una sesión del lab

Al cerrar la sesión del Learner Lab la instancia se detiene. Al volver, enciéndela desde la
consola y **no hay que hacer nada más**: Docker arranca solo y los contenedores tienen
`restart: unless-stopped`. Solo verifica:

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
docker compose --profile todo ps
```

La IP pública cambia en cada encendido; la privada se conserva.

## 12) Actualizar el entorno

Cuando el docente publique cambios en el repositorio:

```bash
cd ~/ADY1103-Activities
git pull
cd Casos/AndysMotors/demo
docker build -t andys-motors:local ./app
docker compose --profile todo up -d
```

`up -d` recrea solo los contenedores cuya imagen o configuración cambió. Los datos de la base
se conservan.

## 13) Apagar

```bash
docker compose --profile todo down        # conserva los datos
docker compose --profile todo down -v     # borra también la base de datos
```

Al terminar el ramo, **termina** la instancia (no basta con detenerla): el Learner Lab cuenta
las instancias detenidas dentro de su tope.

## 14) Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | No volviste a entrar después de `usermod` | `exit` y conectarse de nuevo |
| `docker: 'compose' is not a docker command` | Falta el plugin de Compose (Amazon Linux) | Repetir el bloque de descarga del paso 3 |
| `pull access denied for andys-motors` | Se levantó el entorno sin construir la imagen | `docker build -t andys-motors:local ./app` |
| El puerto 5432 ya está en uso | La máquina tiene otro PostgreSQL | Agregar `DB_PUBLISH_PORT=5433` al `.env` |
| Contenedores reiniciándose o la instancia muy lenta | Falta RAM | Usar `t3.small` o mayor |
| No existe `/var/log/andysmotors` | Imagen construida con una versión anterior del repositorio | `git pull`, reconstruir la imagen y `docker compose --profile todo up -d` |
| El sitio no abre desde el navegador | Falta la regla del puerto 80 | Revisar el grupo de seguridad |
| El generador no envía tráfico | La hora simulada está en la madrugada | Usar `--hora-inicio 9` |
| `/admin/fallas` devuelve 401 | Token distinto al del `.env` | `export ANDYS_ADMIN_TOKEN=<valor del .env>` |
