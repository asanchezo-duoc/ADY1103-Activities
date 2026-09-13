#!/usr/bin/env bash
#
# Inyecta carga controlada en ServerC para que los graficos de PromQL no sean
# lineas planas.
#
# Genera dos tipos de carga, en paralelo y en segundo plano:
#   - CPU: N procesos en bucle ocupado (uno por nucleo por defecto). Sube
#          node_cpu_seconds_total en los modos user/system y baja el modo idle.
#   - RED: descarga repetida de un archivo hacia /dev/null. Sube
#          node_network_receive_bytes_total en la interfaz fisica.
#
# No instala nada: usa solo bash, curl o wget. Al terminar (o al cortar con
# Ctrl+C) mata todos los procesos que lanzo.
#
# Uso tipico (desde ServerC):
#   ./inject_load.sh                       # 300s, todos los nucleos, CPU + red
#   ./inject_load.sh --duration 600        # 10 minutos
#   ./inject_load.sh --cpus 2 --no-net     # solo CPU, 2 nucleos
#   ./inject_load.sh --no-cpu              # solo red
#
# Mientras corre, abrir Grafana > Explore (o Prometheus > Graph) y observar:
#   (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))) * 100
#   rate(node_network_receive_bytes_total{device!="lo"}[1m]) * 8 / 1024 / 1024

set -uo pipefail

DURATION=300
CPUS=""
DO_CPU=1
DO_NET=1
# Endpoint de descarga de prueba (Cloudflare speed test, 100 MB por request).
NET_URL="https://speed.cloudflare.com/__down?bytes=104857600"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="${2:-}"; shift 2 ;;
    --cpus)     CPUS="${2:-}";     shift 2 ;;
    --net-url)  NET_URL="${2:-}";  shift 2 ;;
    --no-cpu)   DO_CPU=0;          shift ;;
    --no-net)   DO_NET=0;          shift ;;
    -h|--help)  usage 0 ;;
    *) echo "Opcion desconocida: $1" >&2; usage 1 ;;
  esac
done

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -le 0 ]]; then
  echo "ERROR: --duration debe ser un numero entero de segundos mayor que 0." >&2
  exit 1
fi

# Si no se indico --cpus, usar todos los nucleos disponibles.
if [[ -z "$CPUS" ]]; then
  CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi
if ! [[ "$CPUS" =~ ^[0-9]+$ ]] || [[ "$CPUS" -le 0 ]]; then
  echo "ERROR: --cpus debe ser un numero entero mayor que 0." >&2
  exit 1
fi

PIDS=()

cleanup() {
  echo ""
  echo "==> Deteniendo la carga..."
  for pid in "${PIDS[@]:-}"; do
    [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null
  done
  # Los hijos de los loops de red (curl/wget) pueden sobrevivir al kill del padre.
  wait 2>/dev/null
  echo "==> Listo. La CPU deberia volver a su nivel base en ~1 minuto"
  echo "    (rate() promedia sobre la ventana, asi que el grafico baja de a poco)."
}
trap cleanup EXIT INT TERM

echo "=========================================="
echo " Inyeccion de carga en ServerC"
echo "=========================================="
echo " Duracion : ${DURATION}s"
[[ "$DO_CPU" -eq 1 ]] && echo " CPU      : ${CPUS} proceso(s) en bucle ocupado"
[[ "$DO_NET" -eq 1 ]] && echo " Red      : descarga repetida desde ${NET_URL%%\?*}"
echo "=========================================="
echo ""

# --- Carga de CPU -----------------------------------------------------------------
# Un bucle ocupado ("busy loop") mantiene el nucleo al 100%: el kernel deja de
# contabilizar tiempo en mode="idle" y lo pasa a mode="user".
if [[ "$DO_CPU" -eq 1 ]]; then
  for ((i = 1; i <= CPUS; i++)); do
    ( while :; do :; done ) &
    PIDS+=("$!")
  done
  echo "==> ${CPUS} proceso(s) de CPU lanzados."
fi

# --- Carga de red -----------------------------------------------------------------
if [[ "$DO_NET" -eq 1 ]]; then
  if command -v curl >/dev/null 2>&1; then
    DL_CMD=(curl -s -o /dev/null --max-time 120)
  elif command -v wget >/dev/null 2>&1; then
    DL_CMD=(wget -q -O /dev/null --timeout=120)
  else
    echo "AVISO: no hay curl ni wget instalado; se omite la carga de red." >&2
    DL_CMD=()
  fi

  if [[ "${#DL_CMD[@]}" -gt 0 ]]; then
    (
      while :; do
        "${DL_CMD[@]}" "$NET_URL" || sleep 2
      done
    ) &
    PIDS+=("$!")
    echo "==> Descarga en bucle lanzada."
  fi
fi

echo ""
echo "Carga activa. Observa los graficos en Grafana (Explore) o en Prometheus."
echo "Corta antes de tiempo con Ctrl+C si lo necesitas."
echo ""

# Cuenta regresiva visible, para no dejar la consola muda.
REMAINING="$DURATION"
while [[ "$REMAINING" -gt 0 ]]; do
  printf "\r  Tiempo restante: %4ds " "$REMAINING"
  sleep 5
  REMAINING=$((REMAINING - 5))
done
printf "\r                              \r"
