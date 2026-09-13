#!/usr/bin/env python3
"""Herramienta de apoyo para explorar el catalogo de metricas de ServerC y
autoverificar las consultas del laboratorio.

Solo usa la libreria estandar de Python 3 (no requiere `pip install`).

Subcomandos
-----------
  list      Lista los nombres de metrica que Prometheus tiene guardados para el
            job indicado (por defecto "node"). Acepta un filtro por substring.

  describe  Muestra el "# HELP" y "# TYPE" de una metrica leyendolos directo del
            endpoint /metrics de ServerC, mas las series y labels que Prometheus
            tiene de ella ahora mismo.

  check     Ejecuta las consultas de referencia del laboratorio contra la API de
            Prometheus e informa cuales devuelven datos y cuales no.

Ejemplos
--------
  # cuantas metricas distintas publica ServerC
  ./promql_lab.py list

  # buscar todas las metricas de memoria
  ./promql_lab.py list memory

  # que significa exactamente esta metrica
  ./promql_lab.py describe node_context_switches_total

  # verificar que el laboratorio quedo funcionando
  ./promql_lab.py check

Variables de entorno (o flags equivalentes):
  PROMETHEUS_URL   default http://localhost:9090
  SERVERC_URL      default http://localhost:9100
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PROM = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
DEFAULT_NODE = os.environ.get("SERVERC_URL", "http://localhost:9100")

# Consultas de referencia del laboratorio: (titulo, query, pista si sale vacia)
REFERENCE_QUERIES = [
    (
        "Target de ServerC arriba",
        'up{job="node"}',
        "El job 'node' no existe o esta DOWN. Revisa el Paso 4 del README.",
    ),
    (
        "Memoria total del host (gauge crudo)",
        "node_memory_MemTotal_bytes",
        "Prometheus no tiene metricas node_*. Revisa que el target este UP.",
    ),
    (
        "Memoria en uso (%)",
        "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100",
        "Falta node_memory_MemAvailable_bytes: revisa los montajes de /proc.",
    ),
    (
        "Trafico de red de entrada (bytes/seg)",
        'rate(node_network_receive_bytes_total{device!="lo"}[5m])',
        "Sin datos suficientes: rate() necesita 2 muestras. Espera ~1 minuto.",
    ),
    (
        "Trafico de red de entrada (Mbps)",
        'rate(node_network_receive_bytes_total{device!="lo"}[5m]) * 8 / 1024 / 1024',
        "Mismo caso anterior: espera a que Prometheus junte muestras.",
    ),
    (
        "CPU en uso por nucleo (%)",
        '(1 - rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100',
        "Falta node_cpu_seconds_total: revisa --path.procfs en ServerC.",
    ),
    (
        "CPU en uso consolidada por servidor (%)",
        '(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100',
        "Mismo caso anterior.",
    ),
]


def http_get_json(url: str, timeout: int = 10) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def http_get_text(url: str, timeout: int = 15) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def prom_api(base: str, path: str, params: dict) -> dict:
    url = f"{base.rstrip('/')}/api/v1/{path}?{urllib.parse.urlencode(params, doseq=True)}"
    try:
        data = http_get_json(url)
    except urllib.error.URLError as exc:
        die(f"no se pudo consultar Prometheus en {base} ({exc.reason}).\n"
            f"       Revisa que ServerA este arriba o exporta PROMETHEUS_URL.")
    if data.get("status") != "success":
        die(f"Prometheus respondio con error: {data.get('error', 'desconocido')}")
    return data


def cmd_list(args: argparse.Namespace) -> int:
    selector = f'{{job="{args.job}"}}'
    data = prom_api(args.prometheus, "label/__name__/values", {"match[]": selector})
    names = sorted(data.get("data", []))

    if not names:
        print(f"Prometheus no tiene ninguna metrica para job=\"{args.job}\".")
        print("Revisa en http://<IP_SERVERA>:9090/targets que el job aparezca UP.")
        return 1

    filtered = [n for n in names if args.filtro.lower() in n.lower()] if args.filtro else names

    print(f"Metricas con job=\"{args.job}\": {len(names)} en total", end="")
    if args.filtro:
        print(f" | {len(filtered)} coinciden con '{args.filtro}'")
    else:
        print()
    print("-" * 60)
    for name in filtered:
        print(f"  {name}")
    if not filtered:
        print("  (ninguna coincidencia; prueba otro texto de busqueda)")
    return 0


def cmd_describe(args: argparse.Namespace) -> int:
    metric = args.metrica

    # 1) HELP y TYPE, leidos del endpoint /metrics de ServerC
    print(f"== {metric} ==")
    try:
        raw = http_get_text(f"{args.serverc.rstrip('/')}/metrics")
        help_line = next((l for l in raw.splitlines() if l.startswith(f"# HELP {metric} ")), None)
        type_line = next((l for l in raw.splitlines() if l.startswith(f"# TYPE {metric} ")), None)
        print(f"  HELP : {help_line[len(f'# HELP {metric} '):] if help_line else '(no encontrada en /metrics)'}")
        print(f"  TYPE : {type_line[len(f'# TYPE {metric} '):] if type_line else '(no encontrada en /metrics)'}")
    except urllib.error.URLError as exc:
        print(f"  (no se pudo leer {args.serverc}/metrics: {exc.reason})")
        print("  Sugerencia: corre este comando desde ServerC, o exporta SERVERC_URL.")

    # 2) Series actuales en Prometheus
    data = prom_api(args.prometheus, "query", {"query": metric})
    result = data.get("data", {}).get("result", [])
    print(f"  SERIES en Prometheus ahora: {len(result)}")
    if not result:
        print("  (sin series: la metrica no existe, o el target esta DOWN)")
        return 1

    label_keys = sorted({k for s in result for k in s["metric"] if k != "__name__"})
    print(f"  LABELS: {', '.join(label_keys) if label_keys else '(ninguno)'}")
    print("-" * 60)
    for serie in result[: args.limite]:
        labels = ",".join(f'{k}="{v}"' for k, v in sorted(serie["metric"].items()) if k != "__name__")
        valor = serie["value"][1]
        print(f"  {{{labels}}}  ->  {valor}")
    if len(result) > args.limite:
        print(f"  ... y {len(result) - args.limite} series mas (usa --limite para ver mas)")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    print("Verificacion de las consultas de referencia del laboratorio")
    print(f"Prometheus: {args.prometheus}")
    print("=" * 72)

    fallos = 0
    for titulo, query, pista in REFERENCE_QUERIES:
        data = prom_api(args.prometheus, "query", {"query": query})
        result = data.get("data", {}).get("result", [])
        if result:
            # Se ordenan de mayor a menor: con varias series (una por nucleo o por
            # interfaz) las primeras suelen valer 0 y dan la falsa impresion de fallo.
            valores = sorted((float(s["value"][1]) for s in result), reverse=True)
            muestra = ", ".join(f"{v:,.2f}" for v in valores[:3])
            extra = f" (+{len(valores) - 3} series mas, de mayor a menor)" if len(valores) > 3 else ""
            print(f"  [ OK ]  {titulo}")
            print(f"          {query}")
            print(f"          -> {muestra}{extra}")
        else:
            fallos += 1
            print(f"  [VACIO] {titulo}")
            print(f"          {query}")
            print(f"          -> {pista}")
        print()

    print("=" * 72)
    if fallos == 0:
        print("Todas las consultas devuelven datos. El laboratorio quedo operativo.")
    else:
        print(f"{fallos} de {len(REFERENCE_QUERIES)} consultas sin datos. Revisa las pistas de arriba")
        print("y la seccion de Troubleshooting del README.")
    return 1 if fallos else 0


def main() -> int:
    # Permite encadenar la salida con `| head` o `| grep` sin que Python reviente
    # con BrokenPipeError cuando el comando de la derecha cierra la tuberia.
    try:
        import signal
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (ImportError, AttributeError, ValueError):
        pass

    parser = argparse.ArgumentParser(
        description="Explorador de metricas y verificador del laboratorio Act2-3.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--prometheus", default=DEFAULT_PROM,
                        help=f"URL de Prometheus en ServerA (default: {DEFAULT_PROM})")
    parser.add_argument("--serverc", default=DEFAULT_NODE,
                        help=f"URL de Node Exporter en ServerC (default: {DEFAULT_NODE})")

    sub = parser.add_subparsers(dest="comando", required=True)

    p_list = sub.add_parser("list", help="lista los nombres de metrica disponibles")
    p_list.add_argument("filtro", nargs="?", default="", help="filtra por substring, ej: memory")
    p_list.add_argument("--job", default="node", help='job a consultar (default: "node")')
    p_list.set_defaults(func=cmd_list)

    p_desc = sub.add_parser("describe", help="muestra HELP, TYPE, labels y series de una metrica")
    p_desc.add_argument("metrica", help="nombre exacto, ej: node_context_switches_total")
    p_desc.add_argument("--limite", type=int, default=10, help="cuantas series mostrar (default 10)")
    p_desc.set_defaults(func=cmd_describe)

    p_check = sub.add_parser("check", help="ejecuta las consultas de referencia y verifica el lab")
    p_check.set_defaults(func=cmd_check)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
