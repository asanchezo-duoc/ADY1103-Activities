# EA3 - Act 3.3: Del log al dashboard: un ataque SSH y la CPU en una sola pantalla

Guia paso a paso para llevar el log de autenticacion de un servidor Red Hat hasta un
**dashboard de CloudWatch** que muestre, al mismo tiempo, un ataque SSH y el consumo de CPU
de la maquina.

> **Video de la actividad**: _(enlace pendiente)_

> **Depende de [EA3/Act3-1](../Act3-1)**: se asume que tienes la instancia Red Hat corriendo,
> con el CloudWatch Agent instalado y enviando metricas.

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Que vas a construir](#2-que-vas-a-construir)
3. [Paso 1 - Por que no entra Instance Connect](#3-paso-1---por-que-no-entra-instance-connect)
4. [Paso 2 - Instalar EC2 Instance Connect en Red Hat](#4-paso-2---instalar-ec2-instance-connect-en-red-hat)
5. [Paso 3 - Sumar logs al agente](#5-paso-3---sumar-logs-al-agente)
6. [Paso 4 - Verificar que los logs llegan](#6-paso-4---verificar-que-los-logs-llegan)
7. [Paso 5 - Generar el ataque](#7-paso-5---generar-el-ataque)
8. [Paso 6 - Logs Insights, de menos a mas](#8-paso-6---logs-insights-de-menos-a-mas)
9. [Paso 7 - Retencion](#9-paso-7---retencion)
10. [Paso 8 - Crear la alarma](#10-paso-8---crear-la-alarma)
11. [Paso 9 - Construir el dashboard](#11-paso-9---construir-el-dashboard)
12. [Paso 10 - Correlacion: ataque y CPU](#12-paso-10---correlacion-ataque-y-cpu)
13. [Paso 11 - El dashboard como codigo](#13-paso-11---el-dashboard-como-codigo)
14. [Paso 12 - Limpieza](#14-paso-12---limpieza)
15. [Evidencias esperadas](#15-evidencias-esperadas)
16. [Troubleshooting](#16-troubleshooting)
17. [Checklist de verificacion](#17-checklist-de-verificacion)

---

## 1) Objetivo de la actividad

Que seas capaz de:

- Habilitar **EC2 Instance Connect** en una distribucion que no lo trae instalado.
- Enviar un archivo de log a **CloudWatch Logs** con el CloudWatch Agent.
- Consultar logs con **Logs Insights**: `fields`, `filter`, `stats`, `bin()` y `parse`.
- Definir una **politica de retencion** con criterio de costo (FinOps).
- Crear una **alarma** y mostrarla en un dashboard.
- **Correlacionar** en un mismo panel metricas, logs, alarmas y un runbook.
- Leer el JSON de un dashboard y entender por que se trata como codigo.

## 2) Que vas a construir

```
EC2 Red Hat  -->  CloudWatch Agent  -->  CloudWatch Logs  -->  Logs Insights  -->  Dashboard
/var/log/secure     lee y envia          grupo /rhel/secure     consultas          ataque SSH + CPU
```

El dashboard final, `Seguridad-SSH-RHEL`, tiene cuatro widgets:

| Posicion | Widget | Origen |
|---|---|---|
| Arriba a la izquierda | CPU de la instancia (%) | Metrica `AWS/EC2` |
| Arriba a la derecha | Top 10 IPs atacantes | Consulta de Logs Insights |
| Abajo a la izquierda | Estado de la alarma de CPU | Alarma `CPU-alta-RHEL` |
| Abajo al centro | Runbook | Texto Markdown |

> La CPU va **arriba a la izquierda** por el patron de lectura en F: es lo primero que mira
> quien abre el panel.

## 3) Paso 1 - Por que no entra Instance Connect

**EC2** > tu instancia > **Conectar** > **Conexion de la instancia EC2** > usuario `ec2-user`
> **Conectar**.

Resultado: **No se pudo conectar a la instancia**.

EC2 Instance Connect funciona asi: la consola genera una **llave SSH temporal** (valida 60
segundos), se la entrega al servicio de AWS y el `sshd` de la instancia la consulta en el
momento del login. Para eso, la instancia necesita un paquete que le ensenie a `sshd` a hacer
esa consulta. **Amazon Linux y Ubuntu lo traen instalado. Red Hat no.**

## 4) Paso 2 - Instalar EC2 Instance Connect en Red Hat

Como Instance Connect aun no funciona, entramos **una unica vez** con la llave desde la
terminal del Learner Lab:

```bash
ssh -i ~/.ssh/labsuser.pem -o StrictHostKeyChecking=no ec2-user@<IP_PUBLICA>
```

Instala el paquete oficial de AWS y su modulo de SELinux:

```bash
sudo dnf install -y \
  https://amazon-ec2-instance-connect-us-west-2.s3.us-west-2.amazonaws.com/latest/linux_amd64/ec2-instance-connect.rhel8.rpm \
  https://amazon-ec2-instance-connect-us-west-2.s3.us-west-2.amazonaws.com/latest/linux_amd64/ec2-instance-connect-selinux.noarch.rpm
```

En Red Hat el paquete instala el script `/opt/aws/bin/eic_run_authorized_keys`, pero **no lo
activa** en `sshd`. Compruebalo:

```bash
sudo sshd -T | grep -i authorizedkeyscommand
# authorizedkeyscommand none
```

Activalo con un archivo propio en `sshd_config.d`:

```bash
sudo tee /etc/ssh/sshd_config.d/40-ec2-instance-connect.conf <<'EOF'
AuthorizedKeysCommand /opt/aws/bin/eic_run_authorized_keys %u %f
AuthorizedKeysCommandUser ec2-instance-connect
EOF

sudo sshd -t && sudo systemctl restart sshd
sudo sshd -T | grep -i authorizedkeyscommand
# authorizedkeyscommand /opt/aws/bin/eic_run_authorized_keys %u %f
# authorizedkeyscommanduser ec2-instance-connect
```

> `sshd -t` valida la configuracion **antes** de reiniciar. Si tiene un error y reinicias
> igual, puedes quedarte sin acceso SSH.

Sal con `exit` y vuelve a probar **Conectar** desde la consola: ahora se abre la terminal en
el navegador. **Desde aqui, todo se hace en esa terminal.**

## 5) Paso 3 - Sumar logs al agente

Revisa la configuracion actual: solo envia metricas.

```bash
cat /opt/aws/amazon-cloudwatch-agent/etc/config.json
```

Agregale la seccion `logs`:

```bash
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json > /dev/null <<'EOF'
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "cpu":  { "measurement": ["cpu_usage_user", "cpu_usage_system", "cpu_usage_idle"], "totalcpu": true },
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] },
      "swap": { "measurement": ["swap_used_percent"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/secure", "log_group_name": "/rhel/secure", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
EOF
```

| Clave | Que hace |
|---|---|
| `file_path` | El archivo que se lee. En Red Hat, los eventos de SSH y `sudo` van a `/var/log/secure` |
| `log_group_name` | El **grupo** de CloudWatch Logs. Si no existe, el agente lo crea |
| `log_stream_name: {instance_id}` | Un **stream** por instancia, con su ID como nombre |

Recarga el agente:

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
```

## 6) Paso 4 - Verificar que los logs llegan

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

Debe decir `"status": "running"`.

En la consola: **CloudWatch** > **Registros** > **Administracion de registros** > `/rhel/secure`
> el stream con el ID de tu instancia.

Veras tus propios logins. Busca las lineas de `eic-curl-authorized-keys` seguidas de
`Accepted publickey`: es Instance Connect validando la llave temporal.

Para verlo en tiempo real: boton **Empezar a seguir** (**Live Tail**). Dejalo abierto para el
siguiente paso.

## 7) Paso 5 - Generar el ataque

Desde **otra maquina** (la terminal del Learner Lab), intenta entrar 40 veces con usuarios
inexistentes:

```bash
for i in {1..40}; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no admin$i@<IP_PUBLICA> 2>/dev/null
done
```

En Live Tail aparecen lineas como esta:

```
sshd-session[3125]: Invalid user admin12 from 32.186.26.168 port 57438
```

> **Importante**: en las instancias de AWS la autenticacion por contrasenia viene
> **desactivada**. Por eso no veras `Failed password`, sino **`Invalid user`**. Las consultas
> filtran por ese texto.

> **Dato**: es posible que no lleguen los 40 intentos. Las versiones recientes de OpenSSH
> **penalizan** a una IP que se conecta muchas veces sin autenticarse, y la desconectan antes
> de registrar el usuario. Veras lineas `drop connection ... penalty: connections without
> attempting authentication`. Es una defensa nativa, no un error.

## 8) Paso 6 - Logs Insights, de menos a mas

**CloudWatch** > **Registros** > **Logs Insights**. En **Alcance de la consulta** elige el grupo
`/rhel/secure` y el rango **30m**. Ejecuta las consultas en orden y **mira el resultado de cada
una antes de pasar a la siguiente**.

> En la consola nueva, la primera linea del editor es `SOURCE ... |`, generada a partir del
> grupo elegido. **No la borres**: escribe tu consulta a partir de la segunda linea.

**Consulta 1 - Los ultimos 20 eventos**

```
fields @timestamp, @message
| sort @timestamp desc
| limit 20
```

**Consulta 2 - Solo los intentos fallidos**

```
fields @timestamp, @message
| filter @message like /Invalid user/
| sort @timestamp desc
```

**Consulta 3 - Intentos por bloques de 5 minutos**

```
filter @message like /Invalid user/
| stats count(*) as intentos by bin(5m)
```

Con `stats` aparece la vista **Visualizacion**: elige **Barra** para ver el histograma del
ataque.

**Consulta 4 - Top 10 de IPs atacantes**

```
filter @message like /Invalid user/
| parse @message "Invalid user * from * port" as usuario, ip
| stats count(*) as intentos by ip
| sort intentos desc
| limit 10
```

`parse` usa `*` como comodin: el primero se guarda en `usuario` y el segundo en `ip`.

Guarda esta ultima consulta: **Consultas guardadas** > **Guardar** > nombre
`Top10-IPs-SSH-Invalid-user`. Es el puente hacia el dashboard.

## 9) Paso 7 - Retencion

Por defecto, un grupo de logs guarda todo **para siempre** (*No vence nunca*), y en una cuenta
real eso se paga todos los meses.

`/rhel/secure` > **Acciones** > **Editar configuracion de retencion** > **2 semanas (14 dias)**
> **Guardar**.

La regla de FinOps:

| Tipo de log | Retencion tipica | Por que |
|---|---|---|
| Debug / aplicacion | Dias | Sirve para diagnosticar ahora; despues es ruido caro |
| Autenticacion / auditoria | Anios | Normativas y auditorias lo exigen |

Para guardar anios **sin pagar CloudWatch**: **Acciones** > **Exportar datos a Amazon S3**
(almacenamiento frio). Despues se consultan con **Amazon Athena**. En esta actividad solo
ubicalo; **no lo ejecutes**.

## 10) Paso 8 - Crear la alarma

**CloudWatch** > **Alarmas** > **Crear alarma** > **Seleccione una metrica** > **EC2** >
**Metricas por instancia** > `CPUUtilization` de tu instancia.

| Campo | Valor |
|---|---|
| Estadistica | Media |
| Periodo | **1 minuto** |
| Condicion | **Mayor** que **70** |
| Puntos de datos para la alarma | **2 de 2** |

*2 de 2* significa: la CPU debe superar 70 % durante **dos minutos seguidos**. Asi un pico de
un segundo no despierta a nadie.

En **Notificacion**, quita la accion (**Eliminar**): no tenemos un tema SNS. Confirma
**Proceder sin acciones**. Nombre: `CPU-alta-RHEL` > **Crear alarma**.

## 11) Paso 9 - Construir el dashboard

**CloudWatch** > **Paneles** > **Crear un panel** > `Seguridad-SSH-RHEL`.

**Widget 1 - CPU.** **Metricas** > **Linea** > **EC2** > **Metricas por instancia** >
`CPUUtilization`. Periodo **1 minuto**. Titulo `CPU de la instancia (%)`.

**Widget 2 - Tabla de logs.** **+** > tipo de datos **Registros** > **Tabla de registros**. Se
abre Logs Insights: **Consultas guardadas** > `Top10-IPs-SSH-Invalid-user` > **Ejecutar** >
**Crear**. Titulo `Top 10 IPs atacantes (SSH Invalid user)`. Arrastrala a la derecha de la CPU
y achicala desde su esquina para que quepan lado a lado.

**Widget 3 - Semaforo.** **+** > **Alarmas** > **Estado de la alarma** > marca `CPU-alta-RHEL`
> titulo `Estado: CPU alta` > **Aniadir al panel**.

**Widget 4 - Runbook.** **+** > **Otros tipos de contenido** > **Texto** > en el Markdown:

```markdown
## Runbook: ataque SSH

Si una IP supera **50 intentos**:

1. Bloquear la IP en el Security Group o NACL
2. Avisar al equipo de seguridad (canal #seguridad)
3. Revisar el Top 10 de IPs y el log /rhel/secure

Si la alarma **CPU-alta-RHEL** esta en rojo: revisar procesos con top y correlacionar con el ataque.
```

Por ultimo: actualizacion automatica cada **10 segundos**, rango **1h** y **Guardar**.

## 12) Paso 10 - Correlacion: ataque y CPU

Este es el momento clave. Haz dos cosas **al mismo tiempo**:

En la terminal de Instance Connect, carga la CPU durante 5 minutos:

```bash
for i in 1 2; do timeout 300 yes > /dev/null & done
```

> Se lanzan **dos** procesos porque la `t3.micro` tiene **2 vCPU**. Con uno solo, la CPU
> llega apenas al 50 %.

En la terminal del Learner Lab, repite el ataque del Paso 5.

Vuelve al dashboard. Entre 1 y 2 minutos despues veras:

- El **pico de CPU** en el grafico.
- La IP atacante sumando intentos en la tabla.
- La alarma pasando a **rojo** despues de dos minutos sobre 70 %.

Todo en la misma pantalla, junto al runbook que dice que hacer.

## 13) Paso 11 - El dashboard como codigo

**Acciones** > **Ver o editar origen**. Observa:

- Cada widget tiene `x`, `y`, `width` y `height` en una grilla de **24 columnas**. La tabla
  tiene `"x": 6` porque la CPU ocupa las primeras 6 columnas.
- El widget de logs lleva la **consulta embebida** en `"query"`.
- La alarma se referencia por su **ARN**.

Ese JSON se guarda en Git y se despliega con `aws cloudwatch put-dashboard`, Terraform o
CloudFormation. Igual que cualquier infraestructura como codigo, el panel se vuelve
reproducible.

Cierra con **Cancelar**, sin cambios.

## 14) Paso 12 - Limpieza

| Que | Por que |
|---|---|
| Detener o terminar la instancia | Consume el presupuesto del lab mientras corre |
| Borrar los paneles que no uses | La capa gratuita incluye **3 dashboards** |
| Revisar la retencion | Con 14 dias, los logs se borran solos |
| No ejecutar consultas sobre rangos grandes sin necesidad | Logs Insights cobra por **GB escaneado** |

## 15) Evidencias esperadas

1. Captura del error de Instance Connect **antes** de instalarlo.
2. Captura de `sshd -T` mostrando `eic_run_authorized_keys`.
3. Captura de la terminal de Instance Connect funcionando en el navegador.
4. Captura del grupo `/rhel/secure` con su stream.
5. Captura de Live Tail con lineas `Invalid user`.
6. Captura del resultado de **cada una** de las cuatro consultas.
7. Captura de la retencion en **2 semanas (14 dias)**.
8. Captura del dashboard **durante la correlacion**: pico de CPU, tabla de IPs y alarma en rojo.
9. Respuesta: en tu dashboard, que IP ataco, cuantos intentos registro y cuanto subio la CPU?

## 16) Troubleshooting

| Sintoma | Causa probable | Que hacer |
|---|---|---|
| Instance Connect sigue fallando despues de instalar | El `AuthorizedKeysCommand` no quedo activo | Revisar `sshd -T` y el archivo en `sshd_config.d`, reiniciar `sshd` |
| `sshd -t` muestra un error | Archivo de configuracion mal escrito | Corregirlo **antes** de reiniciar `sshd` |
| No aparece el grupo `/rhel/secure` | El agente no recargo la configuracion | Repetir `fetch-config` y revisar el log del agente |
| No hay lineas `Failed password` | Las instancias de AWS no aceptan contrasenia | Filtrar por `Invalid user` |
| Llegan menos de 40 intentos | Penalizacion de OpenSSH a la IP | Es esperado: lo importante es el patron |
| La consulta 4 no devuelve IPs | El texto del `parse` no coincide | Copiar el texto exacto de una linea real del log |
| La consulta da error al ejecutar | Se borro la linea `SOURCE` | Volver a elegir el grupo en **Alcance de la consulta** |
| La alarma no se pone roja | Solo un proceso `yes`, o aun no pasan 2 minutos | Lanzar los dos procesos y esperar |

## 17) Checklist de verificacion

- [ ] Instance Connect fallando en Red Hat, y explicado por que.
- [ ] Paquetes `ec2-instance-connect` y `ec2-instance-connect-selinux` instalados.
- [ ] `AuthorizedKeysCommand` activo y comprobado con `sshd -T`.
- [ ] Conexion por Instance Connect desde la consola.
- [ ] Seccion `logs` agregada al agente y recargada.
- [ ] Grupo `/rhel/secure` con el stream de la instancia.
- [ ] Ataque generado y visto en Live Tail.
- [ ] Cuatro consultas de Logs Insights ejecutadas, la ultima guardada.
- [ ] Retencion en 14 dias.
- [ ] Alarma `CPU-alta-RHEL` creada (1 minuto, > 70, 2 de 2).
- [ ] Dashboard con CPU, tabla de IPs, alarma y runbook, guardado.
- [ ] Correlacion lograda: pico de CPU, IP atacante y alarma en rojo en la misma pantalla.
- [ ] JSON del dashboard revisado: coordenadas y consulta embebida.
- [ ] Recursos limpiados al terminar.
