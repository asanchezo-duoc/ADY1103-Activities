#!/usr/bin/env bash
#
# Instala y configura Grafana Alloy en el HOST para monitorear metricas de sistema
# (CPU, memoria, disco, red) y enviarlas (push / remote_write) al Prometheus de ServerA.
#
# Pensado para Ubuntu/Debian (por ejemplo una EC2 con AMI Ubuntu). Si usan Amazon Linux /
# RHEL, cambien la seccion de instalacion del paquete por "yum"/"dnf" (ver comentario abajo).
#
# Uso:
#   export PROMETHEUS_REMOTE_WRITE_URL="http://<IP_SERVERA>:9090/api/v1/write"
#   sudo -E ./install-alloy.sh
#
# Requisitos previos en AWS:
#   - El Security Group de esta maquina (donde corre Alloy) debe permitir trafico
#     de SALIDA (outbound) hacia el puerto 9090 de ServerA. Por defecto AWS permite
#     todo el trafico saliente, asi que normalmente no hay que tocar nada aqui.
#   - El Security Group de ServerA debe permitir trafico de ENTRADA en el puerto 9090
#     desde el Security Group / IP privada de esta maquina (ver README.md).

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root (usa: sudo -E ./install-alloy.sh)" >&2
  exit 1
fi

if [[ -z "${PROMETHEUS_REMOTE_WRITE_URL:-}" ]]; then
  echo "ERROR: falta la variable de entorno PROMETHEUS_REMOTE_WRITE_URL." >&2
  echo 'Ejemplo: export PROMETHEUS_REMOTE_WRITE_URL="http://<IP_SERVERA>:9090/api/v1/write"' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Instalando dependencias base..."
apt-get update -y
apt-get install -y gpg curl

echo ">> Agregando el repositorio APT de Grafana..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

# --- Alternativa para Amazon Linux / RHEL / CentOS -------------------------
# cat <<'EOF' > /etc/yum.repos.d/grafana.repo
# [grafana]
# name=grafana
# baseurl=https://rpm.grafana.com
# repo_gpgcheck=1
# enabled=1
# gpgcheck=1
# gpgkey=https://rpm.grafana.com/gpg.key
# sslverify=1
# sslcacert=/etc/pki/tls/certs/ca-bundle.crt
# EOF
# yum install -y alloy
# ----------------------------------------------------------------------------

echo ">> Instalando Grafana Alloy..."
apt-get update -y
apt-get install -y alloy

echo ">> Copiando configuracion basica (config.alloy)..."
install -o root -g root -m 0644 "${SCRIPT_DIR}/alloy-config.alloy" /etc/alloy/config.alloy

echo ">> Guardando variables de entorno del servicio en /etc/default/alloy..."
# El servicio systemd de Alloy lee /etc/default/alloy (EnvironmentFile). Aqui dejamos
# la URL de remote_write disponible para que la funcion env(...) del config.alloy la resuelva.
cat <<EOF > /etc/default/alloy
PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL}"
CUSTOM_ARGS="--config.file=/etc/alloy/config.alloy"
EOF

echo ">> Habilitando e iniciando el servicio..."
systemctl enable alloy
systemctl restart alloy

echo ">> Listo. Estado del servicio:"
systemctl --no-pager status alloy || true

echo ""
echo "Revisa los logs con: journalctl -u alloy -f"
echo "La UI de debug de Alloy (si esta habilitada) queda en http://localhost:12345"
