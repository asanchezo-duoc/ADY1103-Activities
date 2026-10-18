# EA3 - Act 3.2: Tu primer dashboard en CloudWatch, paso a paso

Guia paso a paso para construir **a mano**, widget por widget, un panel de CloudWatch con la
CPU, la RAM, el disco y la red del servidor Red Hat de la actividad anterior.

> **Video de la actividad**: disponible en AVA.

> **Depende de [EA3/Act3-1](../Act3-1)**: se asume que tienes la instancia Red Hat corriendo,
> con el CloudWatch Agent enviando metricas al namespace `CWAgent`.

## Indice

1. [Objetivo de la actividad](#1-objetivo-de-la-actividad)
2. [Que vas a construir](#2-que-vas-a-construir)
3. [Antes de tocar nada: anatomia de un widget](#3-antes-de-tocar-nada-anatomia-de-un-widget)
4. [Paso 1 - Crear el panel](#4-paso-1---crear-el-panel)
5. [Paso 2 - Widget Numero: CPU](#5-paso-2---widget-numero-cpu)
6. [Paso 3 - Widget Numero: RAM](#6-paso-3---widget-numero-ram)
7. [Paso 4 - Widget Medidor: disco](#7-paso-4---widget-medidor-disco)
8. [Paso 5 - Widget Linea: CPU y RAM en el tiempo](#8-paso-5---widget-linea-cpu-y-ram-en-el-tiempo)
9. [Paso 6 - Widget Linea: red](#9-paso-6---widget-linea-red)
10. [Paso 7 - Ordenar y guardar](#10-paso-7---ordenar-y-guardar)
11. [Evidencias esperadas](#11-evidencias-esperadas)
12. [Troubleshooting](#12-troubleshooting)
13. [Checklist de verificacion](#13-checklist-de-verificacion)

---

## 1) Objetivo de la actividad

Que seas capaz de:

- Crear un panel (dashboard) personalizado en CloudWatch.
- Elegir el **tipo de widget** adecuado para cada pregunta: numero, medidor o linea.
- Encontrar una metrica navegando por **namespace** y **dimensiones**.
- Combinar en un mismo grafico metricas nativas (`AWS/EC2`) y del agente (`CWAgent`).
- Ajustar titulo, periodo y rango de un widget.

## 2) Que vas a construir

Un panel llamado `Panel-Alumnos-RHEL` con cinco widgets:

| # | Widget | Tipo | Metrica | Namespace |
|---|---|---|---|---|
| 1 | CPU (%) | Numero | `CPUUtilization` | `AWS/EC2` |
| 2 | RAM usada (%) | Numero | `mem_used_percent` | `CWAgent` |
| 3 | Disco / usado (%) | Medidor 0-100 | `disk_used_percent` | `CWAgent` |
| 4 | CPU y RAM (%) - cada 1 minuto | Linea | `CPUUtilization` + `mem_used_percent` | ambos |
| 5 | Red - entrada y salida (bytes) | Linea | `NetworkIn` + `NetworkOut` | `AWS/EC2` |

## 3) Antes de tocar nada: anatomia de un widget

| Tipo | Responde a | Ejemplo |
|---|---|---|
| **Numero** | Como esta **ahora**? | CPU actual: 0,5 % |
| **Medidor** | Que tan **cerca del limite** esta? | Disco: 23 % de 100 % |
| **Linea** | Como **cambio** en el tiempo? | La CPU subio a las 22:40 |

Cada metrica se encuentra siempre con la misma ruta:

```
Namespace  >  Dimensiones  >  Nombre de la metrica
AWS/EC2    >  Metricas por instancia (InstanceId)  >  CPUUtilization
CWAgent    >  InstanceId  >  mem_used_percent
CWAgent    >  InstanceId, device, fstype, path  >  disk_used_percent
```

## 4) Paso 1 - Crear el panel

**CloudWatch** > **Paneles** > **Crear un panel** > nombre `Panel-Alumnos-RHEL` > **Crear un
panel**.

Se abre la ventana **Agregar un widget**.

## 5) Paso 2 - Widget Numero: CPU

1. Tipo de datos **Metricas**, tipo de widget **Numero** > **Siguiente**.
2. **EC2** > **Metricas por instancia**.
3. En el buscador escribe `CPUUtilization` y presiona Enter.
4. Marca la fila de tu instancia.
5. Haz clic en el **lapiz** junto al titulo y cambialo a `CPU (%)` > **Aplicar**.
6. **Crear widget**.

## 6) Paso 3 - Widget Numero: RAM

1. Boton **+** (arriba a la derecha) > **Metricas** > **Numero** > **Siguiente**.
2. **CWAgent** > **InstanceId** > marca `mem_used_percent`.
3. Titulo: `RAM usada (%)` > **Crear widget**.

> Fijate en el namespace: la RAM **solo existe** en `CWAgent`. Sin el agente de la actividad
> anterior, este widget no se podria construir.

## 7) Paso 4 - Widget Medidor: disco

1. **+** > **Metricas** > **Medidor** > **Siguiente**.
2. **CWAgent** > **InstanceId, device, fstype, path** > marca `disk_used_percent`.
3. Titulo: `Disco / usado (%)`.
4. Pestania **Opciones** > **Rango del medidor**: Min `0`, Max `100`.
5. **Crear widget**.

> Un medidor **no se puede crear** sin rango: la consola muestra *You have to set the gauge
> range*. El rango le da sentido al valor: 23 % significa poco si no sabes que el maximo es 100.

## 8) Paso 5 - Widget Linea: CPU y RAM en el tiempo

1. **+** > **Metricas** > **Linea** > **Siguiente**.
2. **EC2** > **Metricas por instancia** > `CPUUtilization` de tu instancia.
3. Quita el filtro, vuelve a **Todo** > **CWAgent** > **InstanceId** > `mem_used_percent`.
4. Pestania **Metricas diagramadas**: cambia el **Periodo** a **1 minuto**.
5. Titulo: `CPU y RAM (%) - cada 1 minuto` > **Crear widget**.

> Aqui conviven en un mismo grafico una metrica medida **desde afuera** (`AWS/EC2`) y otra
> medida **desde adentro** del sistema operativo (`CWAgent`).

## 9) Paso 6 - Widget Linea: red

1. **+** > **Metricas** > **Linea** > **Siguiente**.
2. **EC2** > **Metricas por instancia**, busca `Network`.
3. Marca `NetworkIn` y `NetworkOut`.
4. **Metricas diagramadas** > Periodo **1 minuto**.
5. Titulo: `Red - entrada y salida (bytes)` > **Crear widget**.

## 10) Paso 7 - Ordenar y guardar

- Los widgets se **mueven** arrastrandolos desde su encabezado.
- Se **redimensionan** desde la esquina inferior derecha.
- Elige el rango **1h** arriba.
- Haz clic en **Guardar**.

> **Un panel que no se guarda se pierde.** La consola lo recuerda con un aviso azul cada vez
> que agregas un widget.

## 11) Evidencias esperadas

1. Captura del panel completo con los cinco widgets.
2. Captura del medidor de disco con su rango 0-100.
3. Captura del grafico de CPU y RAM con periodo de 1 minuto.
4. Explica en dos lineas por que elegiste **Numero**, **Medidor** o **Linea** para cada widget.

## 12) Troubleshooting

| Sintoma | Causa probable | Que hacer |
|---|---|---|
| No aparece `CWAgent` | El agente no esta corriendo | Revisar el Paso 8 de [Act3-1](../Act3-1) |
| No aparece el disco en `InstanceId` | El disco tiene mas dimensiones | Buscarlo en **InstanceId, device, fstype, path** |
| El disco aparece como `--` | Se busco la metrica `used_percent` | El nombre real es **`disk_used_percent`** |
| *You have to set the gauge range* | Medidor sin rango | **Opciones** > Rango del medidor 0-100 |
| El titulo dice el nombre del widget anterior | La consola reutiliza el titulo | Renombrarlo con el lapiz antes de crear |
| El panel quedo vacio al volver | No se guardo | Repetir y presionar **Guardar** |

## 13) Checklist de verificacion

- [ ] Panel `Panel-Alumnos-RHEL` creado.
- [ ] Widget Numero de CPU desde `AWS/EC2`.
- [ ] Widget Numero de RAM desde `CWAgent`.
- [ ] Widget Medidor de disco con rango 0-100.
- [ ] Widget Linea con CPU y RAM y periodo de 1 minuto.
- [ ] Widget Linea con `NetworkIn` y `NetworkOut`.
- [ ] Todos los widgets con titulo legible.
- [ ] Panel guardado.
