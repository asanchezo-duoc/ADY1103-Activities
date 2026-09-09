#!/usr/bin/env python3
"""Genera 7 dias de historia sintetica y los "backfillea" directo en el TSDB
de Prometheus, para que los dashboards de Act2-2 se vean con una semana
completa de tendencia (y no solo los ultimos minutos de trafico real).

Como funciona (sin usar remote_write ni protobuf):
    1. Genera un archivo en formato OpenMetrics con series para las metricas
       de host (node_*) y de la API (http_requests_total, http_request_duration_
       seconds_*, process_*), con un patron diurno/semanal realista.
    2. Copia ese archivo dentro del contenedor de Prometheus (docker cp).
    3. Corre "promtool tsdb create-blocks-from openmetrics" DENTRO del
       contenedor (promtool ya viene incluido en la imagen prom/prometheus).
       Este es el mecanismo de backfill oficialmente soportado por Prometheus:
       https://prometheus.io/docs/prometheus/latest/storage/#backfilling-from-openmetrics-format
    4. Copia los bloques generados a la carpeta de datos (/prometheus).
    5. Reinicia el contenedor de Prometheus para que los cargue (los bloques
       nuevos NO se detectan en caliente, solo al arrancar).

Uso tipico (recien levantado el stack con "docker compose up -d"):

    python3 scripts/backfill_7d_history.py

Requisitos:
    - Docker corriendo y el contenedor "serverA-prometheus" arriba
      (docker compose up -d en ServerA).
    - Nada mas: no se necesita pip install, solo la libreria estandar.

IMPORTANTE (dos gotchas no obvias de OpenMetrics/Prometheus):
    - El timestamp de cada sample en formato OpenMetrics va en SEGUNDOS
      (con decimales opcionales), no en milisegundos como el remote_write de
      Prometheus. Si se usan milisegundos por error, promtool arma bloques
      con fechas absurdas (anos en el futuro) y Prometheus los descarta como
      "obsoletos" al arrancar, sin backfillear nada.
    - El backfill NO puede pisar el rango de tiempo que Prometheus ya tiene
      "en memoria" (su bloque activo / head). Por eso este script termina la
      historia sintetica un poco antes de "ahora" (--end-offset-minutes) y
      valida contra la hora real de arranque del contenedor. Si el contenedor
      lleva mucho rato corriendo con datos reales, sube --end-offset-minutes,
      o levanta el stack de cero (docker compose down -v && docker compose up -d)
      y corre este script inmediatamente despues.
"""

from __future__ import annotations

import argparse
import math
import os
import random
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone


def parse_docker_timestamp(raw: str) -> datetime:
    """Parsea el 'StartedAt' de docker inspect (nanosegundos) con Python 3.9,
    cuyo datetime.fromisoformat solo acepta 0, 3 o 6 digitos de fraccion."""
    raw = raw.strip().replace("Z", "+00:00")
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d*(?=[+-]\d{2}:\d{2}$)", r"\1", raw))

HOST_LABELS = 'job="host",instance="host.docker.internal:9100"'
API_LABELS = 'job="serverB-api",instance="host.docker.internal:8080"'

# Buckets del histograma, iguales a los definidos en ServerB/src/server.js.
LATENCY_BUCKETS = [0.05, 0.1, 0.3, 0.5, 1, 2, 5, "+Inf"]
# Fraccion ACUMULADA de requests que caen en (o antes de) cada bucket "le".
LATENCY_CUMULATIVE_FRACTIONS = {
    0.05: 0.70, 0.1: 0.85, 0.3: 0.95, 0.5: 0.98, 1: 0.995, 2: 0.999, 5: 1.0, "+Inf": 1.0,
}

# Endpoints de ServerB con su tasa base de requests/seg y su latencia promedio.
# "status_mix" son las fracciones de 200/404/500 (deben sumar 1.0).
ROUTES = {
    "/health":        {"base_rps": 0.033, "diurnal": False, "avg_latency": 0.02, "status_mix": {200: 1.0}},
    "/metrics":       {"base_rps": 0.067, "diurnal": False, "avg_latency": 0.03, "status_mix": {200: 1.0}},
    "/api/saludo":    {"base_rps": 0.8,   "diurnal": True,  "avg_latency": 0.03, "status_mix": {200: 1.0}},
    "/api/productos": {"base_rps": 0.6,   "diurnal": True,  "avg_latency": 0.05, "status_mix": {200: 1.0}},
    "/api/random":    {"base_rps": 0.5,   "diurnal": True,  "avg_latency": 0.04, "status_mix": {200: 0.85, 404: 0.10, 500: 0.05}},
    "/api/error":     {"base_rps": 0.02,  "diurnal": True,  "avg_latency": 0.02, "status_mix": {500: 1.0}},
}


def daily_factor(dt: datetime) -> float:
    """Curva 0..1 con valle en la madrugada y peak ~15:00 (horario de oficina)."""
    hour = dt.hour + dt.minute / 60
    return 0.5 + 0.5 * math.sin(2 * math.pi * (hour - 9) / 24)


def weekday_factor(dt: datetime) -> float:
    """Trafico mas bajo el fin de semana (sabado=5, domingo=6)."""
    return 0.35 if dt.weekday() >= 5 else 1.0


def load_factor(dt: datetime) -> float:
    return daily_factor(dt) * weekday_factor(dt)


def noise(spread: float) -> float:
    return random.uniform(-spread, spread)


def le_label(le) -> str:
    return "+Inf" if le == "+Inf" else str(le)


@dataclass
class Metric:
    name: str
    help_text: str
    metric_type: str
    lines: list = None

    def __post_init__(self):
        self.lines = [f"# HELP {self.name} {self.help_text}", f"# TYPE {self.name} {self.metric_type}"]

    def add(self, labels: str, value: float, ts: float) -> None:
        self.lines.append(f"{self.name}{{{labels}}} {value:.6f} {ts:.3f}")


def build_openmetrics(start: datetime, end: datetime, step_seconds: int) -> str:
    random.seed(42)  # reproducible entre corridas

    m_cpu = Metric("node_cpu_seconds_total", "Seconds the CPUs spent in each mode.", "counter")
    m_mem_total = Metric("node_memory_MemTotal_bytes", "Memory information field MemTotal_bytes.", "gauge")
    m_mem_avail = Metric("node_memory_MemAvailable_bytes", "Memory information field MemAvailable_bytes.", "gauge")
    m_disk_total = Metric("node_filesystem_size_bytes", "Filesystem size in bytes.", "gauge")
    m_disk_avail = Metric("node_filesystem_avail_bytes", "Filesystem space available to non-root users in bytes.", "gauge")
    m_net_rx = Metric("node_network_receive_bytes_total", "Network device statistic receive_bytes.", "counter")
    m_net_tx = Metric("node_network_transmit_bytes_total", "Network device statistic transmit_bytes.", "counter")
    m_load1 = Metric("node_load1", "1m load average.", "gauge")
    m_load5 = Metric("node_load5", "5m load average.", "gauge")
    m_load15 = Metric("node_load15", "15m load average.", "gauge")
    m_boot = Metric("node_boot_time_seconds", "Node boot time, in unixtime.", "gauge")
    m_up = Metric("up", "1 = target esta disponible", "gauge")
    m_requests = Metric("http_requests_total", "Cantidad total de requests HTTP recibidas", "counter")
    m_bucket = Metric("http_request_duration_seconds_bucket", "Duracion de las requests HTTP en segundos", "histogram")
    m_sum = Metric("http_request_duration_seconds_sum", "Duracion de las requests HTTP en segundos", "histogram")
    m_count = Metric("http_request_duration_seconds_count", "Duracion de las requests HTTP en segundos", "histogram")
    m_proc_mem = Metric("process_resident_memory_bytes", "Resident memory size in bytes.", "gauge")
    m_proc_cpu = Metric("process_cpu_user_seconds_total", "Total user CPU time spent in seconds.", "counter")

    # Constantes de host (no cambian en el tiempo).
    mem_total_bytes = 17_179_869_184   # 16 GiB
    disk_total_bytes = 107_374_182_400  # 100 GiB
    boot_time = start.timestamp() - 3600  # el host "arranco" 1h antes de la historia

    # Acumuladores de contadores: el valor que se escribe siempre es el TOTAL
    # corriendo hasta ese instante (un contador de Prometheus nunca baja).
    cpu_idle_total = 0.0
    net_rx_total = 0.0
    net_tx_total = 0.0
    proc_cpu_running = 0.0
    requests_running: dict[tuple, float] = {}
    bucket_running: dict[tuple, float] = {}
    sum_running: dict[str, float] = {r: 0.0 for r in ROUTES}
    count_running: dict[str, float] = {r: 0.0 for r in ROUTES}

    step = timedelta(seconds=step_seconds)
    total_steps = int((end - start).total_seconds() // step_seconds) + 1
    t = start

    for i in range(total_steps):
        ts = t.timestamp()
        lf = load_factor(t)

        # --- Host: CPU -------------------------------------------------------
        cpu_usage_pct = max(2.0, min(95.0, 15 + 55 * lf + noise(4)))
        cpu_idle_total += (1 - cpu_usage_pct / 100) * step_seconds
        m_cpu.add(f'{HOST_LABELS},cpu="0",mode="idle"', cpu_idle_total, ts)

        # --- Host: memoria -----------------------------------------------------
        mem_used_pct = max(10.0, min(90.0, 30 + 35 * lf + noise(3)))
        m_mem_total.add(HOST_LABELS, mem_total_bytes, ts)
        m_mem_avail.add(HOST_LABELS, mem_total_bytes * (1 - mem_used_pct / 100), ts)

        # --- Host: disco (tendencia leve al alza durante la semana) ------------
        progress = i / max(total_steps - 1, 1)
        disk_used_pct = 40 + 0.5 * progress * 7
        m_disk_total.add(f'{HOST_LABELS},mountpoint="/",fstype="ext4"', disk_total_bytes, ts)
        m_disk_avail.add(f'{HOST_LABELS},mountpoint="/",fstype="ext4"', disk_total_bytes * (1 - disk_used_pct / 100), ts)

        # --- Host: red -----------------------------------------------------------
        rx_rate = max(500.0, 4000 + 18000 * lf + noise(1500))
        tx_rate = rx_rate * 0.6
        net_rx_total += rx_rate * step_seconds
        net_tx_total += tx_rate * step_seconds
        m_net_rx.add(f'{HOST_LABELS},device="eth0"', net_rx_total, ts)
        m_net_tx.add(f'{HOST_LABELS},device="eth0"', net_tx_total, ts)

        # --- Host: load average y disponibilidad ---------------------------------
        load1 = max(0.05, 0.2 + 3.2 * lf + noise(0.2))
        m_load1.add(HOST_LABELS, load1, ts)
        m_load5.add(HOST_LABELS, load1 * 0.9, ts)
        m_load15.add(HOST_LABELS, load1 * 0.75, ts)
        m_up.add(HOST_LABELS, 1, ts)
        m_boot.add(HOST_LABELS, boot_time, ts)

        # --- API: requests, status codes y latencia -------------------------------
        for route, cfg in ROUTES.items():
            rps = cfg["base_rps"] * (lf if cfg["diurnal"] else 1.0)
            rps = max(0.0, rps + noise(rps * 0.15))
            requests_this_step = rps * step_seconds

            for status, fraction in cfg["status_mix"].items():
                key = (route, status)
                requests_running[key] = requests_running.get(key, 0.0) + requests_this_step * fraction
                m_requests.add(f'{API_LABELS},method="GET",route="{route}",status_code="{status}"', requests_running[key], ts)

            for le in LATENCY_BUCKETS:
                key = (route, le)
                bucket_running[key] = bucket_running.get(key, 0.0) + requests_this_step * LATENCY_CUMULATIVE_FRACTIONS[le]
                m_bucket.add(f'{API_LABELS},method="GET",route="{route}",le="{le_label(le)}"', bucket_running[key], ts)

            sum_running[route] += requests_this_step * cfg["avg_latency"]
            count_running[route] += requests_this_step
            m_sum.add(f'{API_LABELS},method="GET",route="{route}"', sum_running[route], ts)
            m_count.add(f'{API_LABELS},method="GET",route="{route}"', count_running[route], ts)

        m_up.add(API_LABELS, 1, ts)

        proc_mem_val = 40_000_000 + 25_000_000 * lf + noise(3_000_000)
        m_proc_mem.add(API_LABELS, proc_mem_val, ts)

        proc_cpu_running += (0.02 + 0.08 * lf) * step_seconds
        m_proc_cpu.add(API_LABELS, proc_cpu_running, ts)

        t += step

    all_metrics = [
        m_cpu, m_mem_total, m_mem_avail, m_disk_total, m_disk_avail, m_net_rx, m_net_tx,
        m_load1, m_load5, m_load15, m_boot, m_up,
        m_requests, m_bucket, m_sum, m_count, m_proc_mem, m_proc_cpu,
    ]
    body = "\n".join(line for metric in all_metrics for line in metric.lines)
    return body + "\n# EOF\n"


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR ejecutando: {' '.join(cmd)}", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--step-seconds", type=int, default=300, help="resolucion de los datos sinteticos (default 5 min)")
    parser.add_argument("--end-offset-minutes", type=int, default=10, help="cuanto antes de 'ahora' termina la historia sintetica")
    parser.add_argument("--container", default="serverA-prometheus")
    parser.add_argument("--data-dir", default="/prometheus", help="directorio de datos de Prometheus DENTRO del contenedor")
    parser.add_argument("--dry-run", action="store_true", help="solo genera el archivo .prom, no toca Docker")
    args = parser.parse_args()

    end = datetime.now(timezone.utc) - timedelta(minutes=args.end_offset_minutes)
    start = end - timedelta(days=args.days)

    if not args.dry_run:
        started_at_raw = run(["docker", "inspect", "-f", "{{.State.StartedAt}}", args.container]).strip()
        started_at = parse_docker_timestamp(started_at_raw)
        if end >= started_at:
            print(
                f"ERROR: el rango a backfillear (hasta {end.isoformat()}) se solapa con el "
                f"'head' de Prometheus, que ya tiene datos desde que el contenedor arranco "
                f"({started_at.isoformat()}).\n"
                f"Solucion: aumenta --end-offset-minutes, o levanta el stack de cero con "
                f"'docker compose down -v && docker compose up -d' y corre este script "
                f"inmediatamente despues.",
                file=sys.stderr,
            )
            sys.exit(1)

    print(f"Generando datos sinteticos desde {start.isoformat()} hasta {end.isoformat()} "
          f"(paso de {args.step_seconds}s)...")
    content = build_openmetrics(start, end, args.step_seconds)

    with tempfile.NamedTemporaryFile("w", suffix=".prom", delete=False) as f:
        f.write(content)
        local_path = f.name
    # tempfile crea el archivo en modo 600 (solo el dueño); "docker cp" preserva
    # esos permisos dentro del contenedor, donde Prometheus corre como el
    # usuario "nobody" y no podria ni leerlo. Lo abrimos para todos antes de copiarlo.
    os.chmod(local_path, 0o644)
    print(f"Archivo OpenMetrics generado: {local_path} ({len(content) // 1024} KB)")

    if args.dry_run:
        print("--dry-run: no se toco Docker. Revisa el archivo generado arriba.")
        return

    print(f"Copiando el archivo al contenedor {args.container}...")
    run(["docker", "cp", local_path, f"{args.container}:/tmp/backfill_history.prom"])

    print("Generando bloques TSDB con promtool (esto puede tardar unos segundos)...")
    run(["docker", "exec", args.container, "rm", "-rf", "/tmp/backfill_blocks"])
    run(["docker", "exec", args.container, "mkdir", "-p", "/tmp/backfill_blocks"])
    output = run([
        "docker", "exec", args.container, "promtool", "tsdb", "create-blocks-from", "openmetrics",
        "/tmp/backfill_history.prom", "/tmp/backfill_blocks",
    ])
    print(output)

    print(f"Moviendo los bloques generados a {args.data_dir}...")
    run(["docker", "exec", args.container, "sh", "-c", f"cp -r /tmp/backfill_blocks/*/ {args.data_dir}/"])

    print(f"Reiniciando {args.container} para que cargue los bloques nuevos...")
    run(["docker", "restart", args.container])

    print("\nListo. Espera unos segundos a que Prometheus termine de iniciar y luego revisa,")
    print("por ejemplo, http://localhost:9090/graph con la query 'node_load1' y un rango de 7 dias,")
    print("o abre los dashboards de Grafana con el selector de tiempo en 'Last 7 days'.")


if __name__ == "__main__":
    main()
