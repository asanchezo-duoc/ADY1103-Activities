#!/usr/bin/env python3
"""Generador de trafico/errores para ServerB.

Sirve para "ensuciar" el dashboard "API - ServerB" con datos reales mientras se
prueba: pega a los endpoints normales, a /api/random (mezcla 200/404/500) y,
si se pide, tambien a /api/error (siempre 500), para que los paneles de tasa
de requests, tasa de errores y latencia p95/p99 se vean con movimiento.

Solo usa la libreria estandar de Python (urllib + concurrent.futures), para
que cualquier alumno lo pueda correr sin instalar dependencias:

    python3 scripts/generate_traffic.py --duration 120 --rps 10 --error-ratio 0.15

Args principales:
    --host           Host de ServerB (default: localhost)
    --port           Puerto de ServerB (default: 8080)
    --duration       Duracion total en segundos (default: 60)
    --rps            Requests por segundo aproximados (default: 5)
    --error-ratio    Probabilidad (0-1) de que cada request vaya a /api/error
                      en vez de a un endpoint normal (default: 0.1)
"""

import argparse
import random
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# Endpoints "normales": se reparten el resto del trafico (1 - error_ratio).
NORMAL_ENDPOINTS = ["/health", "/api/saludo", "/api/productos", "/api/random"]


def hit(url: str) -> int:
    """Hace un GET y devuelve el status code (o -1 si no pudo conectar)."""
    try:
        # No lanzamos excepcion por 4xx/5xx: solo queremos el codigo real.
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return -1


def pick_endpoint(base_url: str, error_ratio: float) -> str:
    if random.random() < error_ratio:
        return f"{base_url}/api/error"
    return f"{base_url}{random.choice(NORMAL_ENDPOINTS)}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--duration", type=int, default=60, help="segundos totales de carga")
    parser.add_argument("--rps", type=float, default=5, help="requests por segundo aproximados")
    parser.add_argument("--error-ratio", type=float, default=0.1, help="probabilidad (0-1) de pegarle a /api/error")
    parser.add_argument("--workers", type=int, default=10, help="hilos concurrentes para disparar requests")
    args = parser.parse_args()

    base_url = f"http://{args.host}:{args.port}"
    interval = 1.0 / args.rps if args.rps > 0 else 0
    status_counts: dict[int, int] = {}

    print(f"Generando trafico contra {base_url} durante {args.duration}s a ~{args.rps} req/s "
          f"(error_ratio={args.error_ratio})...")

    # time.monotonic() y no time.time(): el reloj de pared puede saltar (NTP,
    # suspension de la maquina, WSL2) y un salto hacia adelante cortaria la
    # generacion de trafico antes de tiempo. El reloj monotono solo avanza.
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = []
        while time.monotonic() - start < args.duration:
            url = pick_endpoint(base_url, args.error_ratio)
            futures.append(pool.submit(hit, url))
            time.sleep(interval)

        for f in futures:
            status = f.result()
            status_counts[status] = status_counts.get(status, 0) + 1

    print("\nResumen de status codes recibidos:")
    for status, count in sorted(status_counts.items()):
        print(f"  {status}: {count}")
    print(f"\nTotal de requests: {sum(status_counts.values())}")
    print("Revisa el dashboard 'API - ServerB' en Grafana para ver el trafico reflejado.")


if __name__ == "__main__":
    main()
