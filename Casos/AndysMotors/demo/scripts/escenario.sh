#!/usr/bin/env bash
#
# Enciende y apaga los escenarios de falla del entorno de Andys Motors.
#
# Cada escenario vive en la plataforma que lo sufre, asi que el script sabe a
# que servidor mandar cada orden.
#
# Uso:
#   ./escenario.sh listar
#   ./escenario.sh activar    agenda_silenciosa
#   ./escenario.sh desactivar agenda_silenciosa
#   ./escenario.sh apagar-todo
#
# Direcciones: por defecto todo apunta a localhost, que es lo correcto cuando el
# entorno corre completo en una maquina. Para el despliegue en varios
# servidores, exporta las IP privadas antes de llamar al script:
#
#   export STOCK_ADDR=10.0.1.11 AGENDA_ADDR=10.0.1.12 CRM_ADDR=10.0.1.13
#   export PAGOS_ADDR=10.0.1.14 GATEWAY_ADDR=10.0.1.14
#   ./escenario.sh activar agenda_silenciosa

set -uo pipefail

TOKEN="${ANDYS_ADMIN_TOKEN:-andys-lab}"

STOCK="${STOCK_ADDR:-localhost}:${STOCK_PORT:-8082}"
AGENDA="${AGENDA_ADDR:-localhost}:${AGENDA_PORT:-8083}"
CRM="${CRM_ADDR:-localhost}:${CRM_PORT:-8084}"
PAGOS="${PAGOS_ADDR:-localhost}:${PAGOS_PORT:-8085}"
GATEWAY="${GATEWAY_ADDR:-localhost}:${GATEWAY_PORT:-8086}"

# Escenario -> plataformas donde hay que aplicarlo.
destinos_de() {
  case "$1" in
    agenda_silenciosa)    echo "$AGENDA" ;;
    crm_huerfano)         echo "$CRM" ;;
    stock_desactualizado) echo "$STOCK" ;;
    gateway_lento)        echo "$GATEWAY" ;;
    gateway_rechazos)     echo "$GATEWAY" ;;
    # db_lenta afecta a todas las plataformas que consultan la base de datos.
    db_lenta)             echo "$STOCK $AGENDA $CRM $PAGOS" ;;
    *)                    echo "" ;;
  esac
}

TODOS="agenda_silenciosa crm_huerfano stock_desactualizado gateway_lento gateway_rechazos db_lenta"

aplicar() {
  local escenario="$1" activo="$2"
  local destinos; destinos="$(destinos_de "$escenario")"

  if [[ -z "$destinos" ]]; then
    echo "ERROR: escenario desconocido '$escenario'." >&2
    echo "Validos: $TODOS" >&2
    return 1
  fi

  for destino in $destinos; do
    local respuesta
    respuesta="$(curl -s -m 5 -X POST "http://$destino/admin/fallas" \
      -H "X-Admin-Token: $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"escenario\":\"$escenario\",\"activo\":$activo}")"
    if echo "$respuesta" | grep -q '"ok":true'; then
      printf "  %-22s %-24s %s\n" "$escenario" "$destino" "$([[ "$activo" == "true" ]] && echo ACTIVADO || echo desactivado)"
    else
      printf "  %-22s %-24s ERROR: %s\n" "$escenario" "$destino" "${respuesta:-sin respuesta}" >&2
    fi
  done
}

listar() {
  echo "Escenarios disponibles y su estado actual:"
  echo
  for destino in "$STOCK" "$AGENDA" "$CRM" "$PAGOS" "$GATEWAY"; do
    local respuesta
    respuesta="$(curl -s -m 5 "http://$destino/admin/fallas" -H "X-Admin-Token: $TOKEN")"
    if [[ -z "$respuesta" ]]; then
      echo "  [$destino] sin respuesta"
      continue
    fi
    # El script de Python entra por stdin y los DATOS por argumento: no se
    # pueden encadenar dos redirecciones de stdin sobre el mismo comando.
    python3 - "$destino" "$respuesta" <<'PY'
import json, sys
destino, cuerpo = sys.argv[1], sys.argv[2]
try:
    datos = json.loads(cuerpo)
except Exception:
    print(f"  [{destino}] respuesta no valida")
    raise SystemExit
print(f"  [{datos['servicio']:<8} {destino}]")
for e in datos["escenarios"]:
    if e["servicio"] in (datos["servicio"], "*"):
        marca = "ACTIVO" if e["activo"] else "  -   "
        print(f"      {marca}  {e['escenario']:<22} {e['descripcion']}")
PY
  done
}

case "${1:-}" in
  listar)      listar ;;
  activar)     [[ -n "${2:-}" ]] || { echo "Falta el nombre del escenario." >&2; exit 1; }; aplicar "$2" true ;;
  desactivar)  [[ -n "${2:-}" ]] || { echo "Falta el nombre del escenario." >&2; exit 1; }; aplicar "$2" false ;;
  apagar-todo) echo "Apagando todos los escenarios:"; for e in $TODOS; do aplicar "$e" false; done ;;
  *)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
