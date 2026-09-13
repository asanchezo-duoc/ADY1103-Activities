#!/usr/bin/env bash
#
# Ejecuta Terraform dentro de un contenedor, tomando las credenciales temporales
# del AWS Academy Learner Lab.
#
# Por que un contenedor: nadie tiene que instalar Terraform, y todos usan la
# misma version. Si prefieres el Terraform que ya tienes instalado, exporta
# TF_LOCAL=1 antes de llamar al script.
#
# Credenciales: el Learner Lab las entrega en el boton "AWS Details" > "AWS CLI".
# Copia ese bloque completo a un archivo .aws-credentials en esta carpeta:
#
#   [default]
#   aws_access_key_id=ASIA...
#   aws_secret_access_key=...
#   aws_session_token=...
#
# Ese archivo esta en .gitignore. Las credenciales EXPIRAN al cerrar la sesion
# del lab: cuando eso pase, vuelve a copiarlas.
#
# Uso:
#   ./scripts/tf.sh init
#   ./scripts/tf.sh plan
#   ./scripts/tf.sh apply
#   ./scripts/tf.sh destroy
#   ./scripts/tf.sh output

set -euo pipefail

TF_VERSION="${TF_VERSION:-1.10}"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS_FILE="$INFRA_DIR/.aws-credentials"

# --- Credenciales -----------------------------------------------------------
if [[ -f "$CREDS_FILE" ]]; then
  # Se parsea el formato del panel del lab, ignorando el encabezado [default],
  # los comentarios y los espacios alrededor del signo igual.
  while IFS='=' read -r clave valor; do
    clave="$(echo "$clave" | tr -d '[:space:]')"
    valor="$(echo "$valor" | tr -d '[:space:]')"
    case "$clave" in
      aws_access_key_id)     export AWS_ACCESS_KEY_ID="$valor" ;;
      aws_secret_access_key) export AWS_SECRET_ACCESS_KEY="$valor" ;;
      aws_session_token)     export AWS_SESSION_TOKEN="$valor" ;;
    esac
  done < <(grep -E '^[[:space:]]*aws_' "$CREDS_FILE")
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  cat >&2 <<'MSG'
ERROR: no hay credenciales de AWS.

Abre el Learner Lab, haz clic en "AWS Details" > "AWS CLI" y copia el bloque
completo a un archivo llamado .aws-credentials dentro de la carpeta infra/.

  [default]
  aws_access_key_id=ASIA...
  aws_secret_access_key=...
  aws_session_token=...

Ese archivo no se versiona. Recuerda que las credenciales expiran cuando se
cierra la sesion del lab: cuando falle con "ExpiredToken", vuelve a copiarlas.
MSG
  exit 1
fi

if [[ -z "${AWS_SESSION_TOKEN:-}" ]]; then
  echo "AVISO: no hay AWS_SESSION_TOKEN. Las credenciales del Learner Lab" >&2
  echo "       siempre traen uno; sin el, casi todas las llamadas van a fallar." >&2
fi

# --- Ejecucion --------------------------------------------------------------
if [[ "${TF_LOCAL:-0}" == "1" ]]; then
  command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform no esta instalado." >&2; exit 1; }
  exec terraform -chdir="$INFRA_DIR" "$@"
fi

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: no hay Docker. Instala Docker, o usa TF_LOCAL=1 si ya tienes Terraform." >&2
  exit 1
}

# Se pasan tambien las variables TF_VAR_* que el usuario tenga exportadas, para
# poder entregar passwords por entorno en vez de escribirlos en un archivo.
ENV_ARGS=(-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN)
while IFS='=' read -r nombre _; do
  ENV_ARGS+=(-e "$nombre")
done < <(env | grep -E '^TF_VAR_' || true)

exec docker run --rm -it \
  -v "$INFRA_DIR:/infra" \
  -w /infra \
  "${ENV_ARGS[@]}" \
  "hashicorp/terraform:$TF_VERSION" \
  "$@"
