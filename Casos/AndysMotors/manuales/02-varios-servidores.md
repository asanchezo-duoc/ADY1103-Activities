# Manual 2: Andys Motors en varios servidores

Guía manual, comando por comando, para levantar el [entorno de demostración](../demo) **con
cada plataforma en su propio servidor**, como describe el caso: siete instancias EC2 que se
hablan por IP privada.

Para la Evaluación Parcial 3 es más simple el [Manual 1](./01-un-servidor.md): una sola
instancia, un solo CloudWatch Agent.

> Todo esto lo hace también el código Terraform de [`infra/`](../infra) de forma automática
> (`topologia = "completa"`). Aquí se hace a mano para entender cada paso.

## Índice

1. [Qué vas a tener al final](#1-qué-vas-a-tener-al-final)
2. [Antes de empezar: la cuota del Learner Lab](#2-antes-de-empezar-la-cuota-del-learner-lab)
3. [Paso 1 - Crear el grupo de seguridad](#3-paso-1---crear-el-grupo-de-seguridad)
4. [Paso 2 - Crear las siete instancias](#4-paso-2---crear-las-siete-instancias)
5. [Paso 3 - Anotar las IP privadas](#5-paso-3---anotar-las-ip-privadas)
6. [Paso 4 - Preparar los siete servidores](#6-paso-4---preparar-los-siete-servidores)
7. [Paso 5 - Levantar servidor por servidor](#7-paso-5---levantar-servidor-por-servidor)
8. [Paso 6 - Verificar desde ServerBorde](#8-paso-6---verificar-desde-serverborde)
9. [Paso 7 - Generar tráfico y fallas](#9-paso-7---generar-tráfico-y-fallas)
10. [Variante con menos servidores](#10-variante-con-menos-servidores)
11. [Al volver a una sesión del lab](#11-al-volver-a-una-sesión-del-lab)
12. [Actualizar el entorno](#12-actualizar-el-entorno)
13. [Apagar](#13-apagar)
14. [Troubleshooting](#14-troubleshooting)

---

## 1) Qué vas a tener al final

| Servidor | Perfil de Compose | Contenedores | Puertos | Necesita en su `.env` | Construye imagen |
|---|---|---|---|---|---|
| ServerData | `data` | postgres | 5432 | — | No |
| ServerStock | `stock` | stock-api | 8082 | `DB_HOST` | Sí |
| ServerAgenda | `agenda` | agenda-api | 8083 | `DB_HOST` | Sí |
| ServerCRM | `crm` | crm-api | 8084 | `DB_HOST` | Sí |
| ServerPagos | `pagos` | pagos-api, gateway-externo | 8085, 8086 | `DB_HOST` | Sí |
| ServerWeb | `web` | web-api | 8081 | `STOCK_HOST`, `AGENDA_HOST`, `CRM_HOST` | Sí |
| ServerBorde | `borde` | haproxy | 80, 8404 | `WEB_HOST`, `STOCK_HOST`, `AGENDA_HOST`, `CRM_HOST`, `PAGOS_HOST` | No |

```
Internet --:80--> ServerBorde ---> ServerWeb ---> ServerStock  --+
                      |                     ---> ServerAgenda --+--> ServerData
                      |                     ---> ServerCRM    --+
                      +---------> ServerPagos (+ gateway) ------+
```

Cada servidor de aplicación escribe los logs de su plataforma en `/var/log/andysmotors/`. Para
llevarlos a CloudWatch, el agente se instala **en cada uno** de esos servidores.

## 2) Antes de empezar: la cuota del Learner Lab

Son **siete instancias**. El Learner Lab tiene un tope de instancias que **cuenta también las
detenidas**: si tienes instancias de otros laboratorios, termínalas antes (detenerlas no
basta). Si aun así no alcanza, usa la [variante con menos servidores](#10-variante-con-menos-servidores).

## 3) Paso 1 - Crear el grupo de seguridad

Un solo grupo para los siete servidores, que permite todo el tráfico **entre ellos** y solo lo
necesario desde fuera.

**EC2** > **Grupos de seguridad** > **Crear grupo de seguridad**:

| Campo | Valor |
|---|---|
| Nombre | `andys-lab-sg` |
| VPC | La VPC por defecto |

Reglas de entrada:

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | `0.0.0.0/0` | Conectarse (EC2 Instance Connect necesita este origen) |
| HTTP | 80 | `0.0.0.0/0` | Sitio público, en ServerBorde |
| TCP personalizado | 8404 | Mi IP | Página de estado y métricas de HAProxy |

Crea el grupo. Luego **edita sus reglas de entrada** y agrega una más, que solo se puede crear
cuando el grupo ya existe:

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| Todo el tráfico | Todos | `andys-lab-sg` (el mismo grupo) | Que los servidores se hablen entre sí por IP privada |

## 4) Paso 2 - Crear las siete instancias

**EC2** > **Lanzar instancias**, una sola vez con **Número de instancias: 7**:

| Campo | Valor |
|---|---|
| Nombre | `andys` (después se renombran) |
| AMI | **Amazon Linux 2023** (recomendada) o **Red Hat** |
| Tipo de instancia | `t3.micro` |
| Par de claves | `vockey` |
| Grupo de seguridad | Seleccionar el existente `andys-lab-sg` |
| Detalles avanzados > Perfil de instancia de IAM | `LabInstanceProfile` |
| Número de instancias | `7` |

Cuando estén creadas, renómbralas en la consola (clic en el nombre): `ServerData`,
`ServerStock`, `ServerAgenda`, `ServerCRM`, `ServerPagos`, `ServerWeb` y `ServerBorde`.

## 5) Paso 3 - Anotar las IP privadas

En la consola, cada instancia muestra su **Dirección IPv4 privada**. Anótalas: se usan en todo
el resto del manual.

| Servidor | IP privada |
|---|---|
| ServerData | |
| ServerStock | |
| ServerAgenda | |
| ServerCRM | |
| ServerPagos | |
| ServerWeb | |
| ServerBorde | (no se necesita) |

Arma con ellas este **bloque de direcciones**. Lo vas a pegar al inicio de cada servidor:

```bash
export IP_DATA=172.31.0.10      # reemplaza cada valor por la IP privada real
export IP_STOCK=172.31.0.11
export IP_AGENDA=172.31.0.12
export IP_CRM=172.31.0.13
export IP_PAGOS=172.31.0.14
export IP_WEB=172.31.0.15
```

> Se usan **IP privadas** a propósito: se conservan cuando la instancia se detiene y se vuelve
> a encender. Las públicas cambian.

## 6) Paso 4 - Preparar los siete servidores

Esto se repite **igual en los siete**. Conéctate a cada uno (EC2 Instance Connect en Amazon
Linux; por SSH con `labsuser.pem` en Red Hat).

### 6.1 Instalar Docker y Git

Amazon Linux 2023:

```bash
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -fsSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

Red Hat:

```bash
sudo dnf install -y dnf-plugins-core git
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

**Cierra la sesión (`exit`) y vuelve a conectarte**, para que se aplique el permiso de Docker.

### 6.2 Clonar y crear el .env

```bash
cd ~
git clone https://github.com/asanchezo-duoc/ADY1103-Activities.git
cd ~/ADY1103-Activities/Casos/AndysMotors/demo

cp .env.example .env
sed -i 's/^DB_PASSWORD=.*/DB_PASSWORD=Andys.Lab_2026/' .env
sed -i 's/^ANDYS_ADMIN_TOKEN=.*/ANDYS_ADMIN_TOKEN=andys-lab/' .env
```

> **La contraseña y el token deben ser idénticos en los siete servidores.** Si ServerData
> tiene una contraseña y ServerStock otra, stock no podrá conectarse a la base.

## 7) Paso 5 - Levantar servidor por servidor

**El orden importa**: primero la base de datos, después las plataformas que dependen de ella,
después el sitio web y al final el balanceador.

En cada servidor, todos los comandos se ejecutan en
`~/ADY1103-Activities/Casos/AndysMotors/demo`, y **primero se pega el bloque de direcciones**
del paso 3.

### 7.1 ServerData

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
docker compose --profile data up -d
docker compose --profile data ps        # postgres debe quedar healthy
```

### 7.2 ServerStock

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
echo "DB_HOST=$IP_DATA" >> .env

docker build -t andys-motors:local ./app
docker compose --profile stock up -d
curl -s http://localhost:8082/health; echo
```

### 7.3 ServerAgenda

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
echo "DB_HOST=$IP_DATA" >> .env

docker build -t andys-motors:local ./app
docker compose --profile agenda up -d
curl -s http://localhost:8083/health; echo
```

### 7.4 ServerCRM

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
echo "DB_HOST=$IP_DATA" >> .env

docker build -t andys-motors:local ./app
docker compose --profile crm up -d
curl -s http://localhost:8084/health; echo
```

### 7.5 ServerPagos

El proveedor externo de pagos (`gateway-externo`) vive en este mismo servidor, porque es la
única dependencia de pagos. No hay que configurar su dirección.

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
echo "DB_HOST=$IP_DATA" >> .env

docker build -t andys-motors:local ./app
docker compose --profile pagos up -d
curl -s http://localhost:8085/health; echo
curl -s http://localhost:8086/health; echo
```

### 7.6 ServerWeb

El sitio web no usa la base de datos: depende de stock, agenda y CRM.

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
cat >> .env <<EOF
STOCK_HOST=$IP_STOCK
AGENDA_HOST=$IP_AGENDA
CRM_HOST=$IP_CRM
EOF

docker build -t andys-motors:local ./app
docker compose --profile web up -d
curl -s http://localhost:8081/api/catalogo | head -c 200; echo
```

Si el catálogo devuelve vehículos, web ya está hablando con stock, y stock con la base de
datos.

### 7.7 ServerBorde

HAProxy usa la imagen oficial: **no se construye la imagen** de Andys Motors aquí.

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
cat >> .env <<EOF
WEB_HOST=$IP_WEB
STOCK_HOST=$IP_STOCK
AGENDA_HOST=$IP_AGENDA
CRM_HOST=$IP_CRM
PAGOS_HOST=$IP_PAGOS
EOF

docker compose --profile borde up -d
docker compose --profile borde ps
```

> Revisa el `.env` de cada servidor con `grep -E '_HOST=' .env`. Si ejecutaste un `echo` dos
> veces quedan líneas repetidas: edita el archivo y deja una sola por variable.

## 8) Paso 6 - Verificar desde ServerBorde

```bash
# Sitio público y catálogo, a través del balanceador
curl -s http://localhost/ | head -c 200; echo
curl -s http://localhost/api/catalogo | head -c 200; echo

# Estado de cada backend en HAProxy: deben estar todos UP
curl -s http://localhost:8404/metrics | grep '^haproxy_server_status' | grep 'state="UP"'
```

Desde tu navegador: `http://<IP_PUBLICA_BORDE>` y `http://<IP_PUBLICA_BORDE>:8404/stats`.

En cada servidor de aplicación, los logs quedan en archivos:

```bash
ls -l /var/log/andysmotors/
```

## 9) Paso 7 - Generar tráfico y fallas

Ambos se ejecutan desde **ServerBorde**, que llega a todas las plataformas por IP privada.

Tráfico de horario comercial durante 30 minutos (en una terminal aparte):

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
python3 scripts/generar_trafico.py --url http://localhost --hora-inicio 9 --factor 1 --duracion 1800
```

Escenarios de falla: el script necesita saber dónde vive cada plataforma.

```bash
cd ~/ADY1103-Activities/Casos/AndysMotors/demo
# (pega aquí el bloque de direcciones)
export ANDYS_ADMIN_TOKEN=andys-lab
export STOCK_ADDR=$IP_STOCK AGENDA_ADDR=$IP_AGENDA CRM_ADDR=$IP_CRM
export PAGOS_ADDR=$IP_PAGOS GATEWAY_ADDR=$IP_PAGOS

./scripts/escenario.sh listar
./scripts/escenario.sh activar    agenda_silenciosa
./scripts/escenario.sh desactivar agenda_silenciosa
```

## 10) Variante con menos servidores

Un servidor puede levantar varios perfiles a la vez. Las plataformas que comparten servidor se
encuentran por nombre de contenedor, así que **solo se configuran las direcciones de las que
están en otra máquina**. Por ejemplo, con tres servidores:

| Servidor | Comando | Necesita en su `.env` |
|---|---|---|
| ServerData | `docker compose --profile data up -d` | — |
| ServerApps | `docker compose --profile stock --profile agenda --profile crm --profile pagos --profile web up -d` | `DB_HOST` |
| ServerBorde | `docker compose --profile borde up -d` | `WEB_HOST`, `STOCK_HOST`, `AGENDA_HOST`, `CRM_HOST` y `PAGOS_HOST`, todas con la IP de ServerApps |

ServerApps necesita construir la imagen y conviene que sea `t3.small`. Usa siempre los mismos
`--profile` en `ps`, `down` y `up` de ese servidor.

## 11) Al volver a una sesión del lab

Enciende las siete instancias desde la consola, **ServerData primero**. Docker arranca solo y
los contenedores tienen `restart: unless-stopped`; las plataformas que arranquen antes que la
base de datos reintentan solas. Verifica en ServerBorde:

```bash
curl -s http://localhost:8404/metrics | grep '^haproxy_server_status' | grep 'state="UP"'
```

Las IP privadas se conservan, así que los `.env` siguen siendo válidos.

## 12) Actualizar el entorno

En cada servidor de aplicación (stock, agenda, crm, pagos y web), con su propio perfil:

```bash
cd ~/ADY1103-Activities
git pull
cd Casos/AndysMotors/demo
docker build -t andys-motors:local ./app
docker compose --profile <perfil> up -d
```

En ServerData y ServerBorde basta con `git pull` y `docker compose --profile <perfil> up -d`.

## 13) Apagar

En cada servidor, con su perfil:

```bash
docker compose --profile <perfil> down
```

En ServerData, `down -v` borra además la base de datos. Al terminar el ramo, **termina** las
siete instancias: el tope del Learner Lab cuenta las detenidas.

## 14) Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| Una plataforma se reinicia con errores de conexión a la base | Falta la regla "Todo el tráfico desde `andys-lab-sg`", o `DB_HOST` está mal | Revisar el grupo de seguridad y `grep DB_HOST .env` |
| `password authentication failed` | La contraseña del `.env` es distinta en ServerData | Dejar la misma en todos y recrear: `docker compose --profile <perfil> up -d --force-recreate` |
| HAProxy marca un backend `DOWN` | Esa plataforma no arrancó, o su IP en el `.env` de ServerBorde está mal | `docker compose --profile <perfil> logs` en ese servidor y revisar `grep _HOST .env` en ServerBorde |
| El catálogo responde con error en ServerWeb | `STOCK_HOST` mal configurado | Revisar el `.env` de ServerWeb y `docker compose --profile web up -d` |
| Cambié el `.env` y no pasó nada | Compose lee el `.env` al crear los contenedores | `docker compose --profile <perfil> up -d` los recrea con la nueva configuración |
| `permission denied ... docker.sock` | No volviste a entrar después de `usermod` | `exit` y conectarse de nuevo |
| `pull access denied for andys-motors` | Falta construir la imagen en ese servidor | `docker build -t andys-motors:local ./app` |
| Las instancias quedan `terminated` al crearlas | Se superó el tope de instancias del lab | Terminar instancias viejas o usar la variante con menos servidores |
| `escenario.sh` responde que no puede conectar | Faltan los `export ..._ADDR` | Repetir el bloque del paso 7 |
