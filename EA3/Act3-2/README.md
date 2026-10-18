# EA3 - Act 3.2: CloudWatch Agent en Red Hat: metricas cada 1 minuto

Guia paso a paso para levantar un servidor **Red Hat Enterprise Linux** en el **AWS Academy
Learner Lab**, instalarle el **agente de CloudWatch** y hacer que envie metricas que EC2 no
puede ver por si solo, como la memoria RAM y el porcentaje de disco usado.

> **Video de la actividad**: _(enlace pendiente)_

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Que vas a construir](#2-que-vas-a-construir)
3. [Requisitos previos](#3-requisitos-previos)
4. [Antes de tocar nada: dos ideas](#4-antes-de-tocar-nada-dos-ideas)
5. [Paso 1 - Entrar a la consola de AWS](#5-paso-1---entrar-a-la-consola-de-aws)
6. [Paso 2 - Crear la instancia Red Hat](#6-paso-2---crear-la-instancia-red-hat)
7. [Paso 3 - Rol LabRole y monitoreo detallado](#7-paso-3---rol-labrole-y-monitoreo-detallado)
8. [Paso 4 - Conectarse por SSH](#8-paso-4---conectarse-por-ssh)
9. [Paso 5 - Instalar el agente](#9-paso-5---instalar-el-agente)
10. [Paso 6 - Configurar el agente con un JSON](#10-paso-6---configurar-el-agente-con-un-json)
11. [Paso 7 - Iniciar el agente](#11-paso-7---iniciar-el-agente)
12. [Paso 8 - Revisar los logs del agente](#12-paso-8---revisar-los-logs-del-agente)
13. [Paso 9 - Ver las metricas en CloudWatch](#13-paso-9---ver-las-metricas-en-cloudwatch)
14. [Evidencias esperadas](#14-evidencias-esperadas)
15. [Troubleshooting](#15-troubleshooting)
16. [Checklist de verificacion](#16-checklist-de-verificacion)

---

## 1) Objetivo de la actividad

Que seas capaz de:

- Lanzar una instancia EC2 con Red Hat y asignarle un **rol de IAM** desde la consola.
- Explicar la diferencia entre el **monitoreo basico** (cada 5 minutos) y el **monitoreo
  detallado** (cada 1 minuto) de EC2.
- Instalar y configurar el **CloudWatch Agent** con un archivo JSON.
- Explicar por que **EC2 no puede medir la RAM** y como el agente resuelve ese vacio.
- Diagnosticar el agente con su estado y sus logs.
- Encontrar en CloudWatch las metricas nativas (`AWS/EC2`) y las del agente (`CWAgent`).

## 2) Que vas a construir

```
+----------------------------+        metricas cada 60 s        +----------------------+
|  EC2 Red Hat (t3.micro)    |  ----------------------------->  |  CloudWatch Metrics  |
|  rol: LabRole              |   AWS/EC2  (CPU, red, disco EBS) |                      |
|  CloudWatch Agent          |   CWAgent  (RAM, % disco, swap)  |                      |
+----------------------------+                                  +----------------------+
```

| Origen | Namespace | Ejemplos | Quien la mide |
|---|---|---|---|
| Hipervisor de AWS | `AWS/EC2` | `CPUUtilization`, `NetworkIn`, `NetworkOut` | AWS, desde afuera de la maquina |
| CloudWatch Agent | `CWAgent` | `mem_used_percent`, `disk_used_percent`, `swap_used_percent` | El agente, desde adentro del sistema operativo |

## 3) Requisitos previos

- Sesion activa de **AWS Academy Learner Lab** (punto verde junto a **AWS**).
- Haber completado [EA3/Act3-1](../Act3-1) o, al menos, saber entrar a la consola desde el
  lab.

No necesitas instalar nada en tu computador: todo se hace desde el navegador.

## 4) Antes de tocar nada: dos ideas

### 4.1 Lo que EC2 ve y lo que no ve

AWS mide tu instancia **desde el hipervisor**, es decir, desde afuera. Desde ahi ve cuanta
CPU consume la maquina virtual o cuantos bytes pasan por su red, pero **no puede ver
dentro del sistema operativo**: no sabe cuanta RAM esta usando Linux ni que tan lleno esta
el disco `/`.

Para eso hace falta un **agente**: un programa que corre dentro de la instancia, lee esos
datos del sistema operativo y los envia a CloudWatch.

### 4.2 Monitoreo basico y detallado

| | Basico | Detallado |
|---|---|---|
| Frecuencia de `AWS/EC2` | 1 punto cada 5 minutos | 1 punto cada 1 minuto |
| Costo | Incluido | Tiene costo adicional en cuentas reales |
| Donde se activa | Viene por defecto | Al crear la instancia o despues, en *Monitoreo* |

El monitoreo detallado solo cambia la frecuencia de las metricas **nativas**. Las del
agente llegan con la frecuencia que tu definas en su JSON (`metrics_collection_interval`).

## 5) Paso 1 - Entrar a la consola de AWS

En el Learner Lab, haz clic en **AWS** (el punto debe estar verde). Se abre la consola en la
region **us-east-1 (Norte de Virginia)**.

## 6) Paso 2 - Crear la instancia Red Hat

**EC2** > **Lanzar instancia**:

| Campo | Valor |
|---|---|
| Nombre | `rhel-cloudwatch-demo` |
| AMI | **Red Hat** (Inicio rapido) |
| Tipo de instancia | `t3.micro` |
| Par de claves | `vockey` |
| Configuracion de red | Crear un grupo de seguridad, permitir **SSH** |

> El usuario por defecto de las AMI de Red Hat es `ec2-user`.

## 7) Paso 3 - Rol LabRole y monitoreo detallado

Antes de lanzar, abre **Detalles avanzados**:

| Campo | Valor | Por que |
|---|---|---|
| Perfil de instancia de IAM | **`LabInstanceProfile`** | Contiene el rol `LabRole`, que le da permiso al agente para escribir en CloudWatch |
| Monitorizacion detallada de CloudWatch | **Habilitar** | Para que `AWS/EC2` llegue cada 1 minuto |

> En el Learner Lab no puedes crear roles propios. El perfil `LabInstanceProfile` ya existe
> y es el que se usa en todos los laboratorios.

Haz clic en **Lanzar instancia** y espera a que quede **En ejecucion**. Copia su **IP publica**.

## 8) Paso 4 - Conectarse por SSH

Usa la **terminal del Learner Lab**: ya trae la llave `~/.ssh/labsuser.pem`.

```bash
ssh -i ~/.ssh/labsuser.pem -o StrictHostKeyChecking=no ec2-user@<IP_PUBLICA>
```

> La terminal del lab tiene un cliente SSH antiguo: la opcion `StrictHostKeyChecking=accept-new`
> **no existe** ahi. Usa `no`.

## 9) Paso 5 - Instalar el agente

```bash
sudo dnf install -y https://amazoncloudwatch-agent.s3.amazonaws.com/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
```

Los mensajes `This system is not registered with an entitlement server` son normales: la
instancia usa los repositorios de Red Hat en AWS (RHUI) y no necesita registro.

## 10) Paso 6 - Configurar el agente con un JSON

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
  }
}
EOF
```

| Clave | Que hace |
|---|---|
| `metrics_collection_interval: 60` | Un punto por minuto |
| `namespace: CWAgent` | Donde apareceran las metricas en CloudWatch |
| `append_dimensions` con `${aws:InstanceId}` | Agrega el **ID de la instancia** a cada metrica. El agente lo reemplaza por el valor real al arrancar |
| `disk` con `used_percent` | En CloudWatch aparece como **`disk_used_percent`** (el agente le antepone `disk_`) |

## 11) Paso 7 - Iniciar el agente

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
```

| Opcion | Significado |
|---|---|
| `-a fetch-config` | Cargar una configuracion |
| `-m ec2` | Modo EC2 (usa el rol de la instancia para autenticarse) |
| `-s` | Reiniciar el agente al terminar |
| `-c file:...` | Ruta del JSON |

Debe terminar con `Configuration validation second phase succeeded`.

## 12) Paso 8 - Revisar los logs del agente

```bash
# 1. Estado: debe decir "running"
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

# 2. Log propio del agente
sudo tail -n 30 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log

# 3. El servicio visto desde systemd
sudo journalctl -u amazon-cloudwatch-agent --no-pager -n 20
```

En el log del agente busca la linea **`Everything is ready. Begin running and processing data.`**
Si el rol no tuviera permisos, aqui veras un `AccessDenied`.

## 13) Paso 9 - Ver las metricas en CloudWatch

**CloudWatch** > **Metricas** > **Todas las metricas**:

1. **EC2** > **Metricas por instancia** > `CPUUtilization` de tu instancia.
2. En **Metricas diagramadas**, cambia el **Periodo** a **1 minuto**: veras un punto por
   minuto gracias al monitoreo detallado.
3. Vuelve a **Examinar**. En **Espacios de nombres personalizados** aparece **CWAgent**.
4. **CWAgent** > **InstanceId** > `mem_used_percent`: el uso de RAM.

> Las metricas del agente tardan **2 a 5 minutos** en aparecer la primera vez.

Responde:

| Pregunta |
|---|
| Que metricas aparecen en `AWS/EC2` y cuales en `CWAgent`? |
| Por que `mem_used_percent` no existe en `AWS/EC2`? |
| De donde sale la dimension `InstanceId` de las metricas del agente? |
| Que pasaria con los graficos de `CPUUtilization` si no hubieras habilitado el monitoreo detallado? |

## 14) Evidencias esperadas

1. Captura de la instancia **En ejecucion**, con el perfil de IAM `LabInstanceProfile`
   visible en sus detalles.
2. Captura del `config.json` con `cat`.
3. Captura de `amazon-cloudwatch-agent-ctl -a status` con `"status": "running"`.
4. Captura del log del agente con `Everything is ready`.
5. Captura de `CPUUtilization` con periodo de 1 minuto.
6. Captura de `mem_used_percent` en el namespace `CWAgent`.
7. Las cuatro preguntas del Paso 9 respondidas.

## 15) Troubleshooting

| Sintoma | Causa probable | Que hacer |
|---|---|---|
| `AccessDenied` en el log del agente | La instancia no tiene el perfil `LabInstanceProfile` | EC2 > instancia > *Acciones* > *Seguridad* > *Modificar rol de IAM* y elegir `LabInstanceProfile`. Reiniciar el agente |
| No aparece `CWAgent` en CloudWatch | Aun no llega el primer envio | Esperar 5 minutos y revisar el log del agente |
| `command-line line 0: unsupported option "accept-new"` | SSH antiguo en la terminal del lab | Usar `-o StrictHostKeyChecking=no` |
| Las metricas `AWS/EC2` vienen cada 5 minutos | Monitoreo detallado desactivado | EC2 > instancia > *Acciones* > *Monitorear y solucionar problemas* > *Administrar monitoreo detallado* |
| En un dashboard no aparece el disco | Se busco `used_percent` | El nombre real en CloudWatch es **`disk_used_percent`** |

## 16) Checklist de verificacion

- [ ] Instancia Red Hat `t3.micro` creada con llave `vockey`.
- [ ] Perfil de IAM `LabInstanceProfile` asignado.
- [ ] Monitoreo detallado habilitado.
- [ ] Conexion por SSH desde la terminal del Learner Lab.
- [ ] Agente instalado con `dnf`.
- [ ] `config.json` creado con `InstanceId` como dimension.
- [ ] Agente iniciado con `fetch-config` y en estado `running`.
- [ ] Log del agente revisado (`Everything is ready`).
- [ ] `CPUUtilization` visto con periodo de 1 minuto.
- [ ] `mem_used_percent` visto en `CWAgent`.
