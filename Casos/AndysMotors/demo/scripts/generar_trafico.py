#!/usr/bin/env python3
"""Genera trafico contra la plataforma de Andys Motors siguiendo la curva
horaria descrita en el caso.

Sin esto los graficos son lineas planas, y sin variacion horaria no se puede
justificar un SLA distinto por franja ni analizar el presupuesto de error.

Curva del caso:

    00:00 - 02:00   trafico bajo
    02:00 - 06:00   trafico practicamente nulo
    06:00 - 09:00   incremento progresivo
    09:00 - 19:00   trafico alto
    19:00 - 22:00   trafico medio
    22:00 - 00:00   trafico bajo

Ademas, los sistemas internos (CRM y pagos) solo tienen actividad relevante
dentro del horario comercial de las sucursales, entre 09:00 y 19:00.

El parametro --factor acelera el tiempo simulado: con el valor por defecto de
60, un minuto real equivale a una hora simulada, asi que un dia completo se
recorre en 24 minutos. Es lo que permite ver el patron dia/noche dentro de una
clase.

Solo usa la libreria estandar de Python 3: no requiere pip install.

Ejemplos
--------
    # Un dia completo en 24 minutos, empezando a medianoche
    ./generar_trafico.py --url http://<IP_BORDE> --hora-inicio 0 --duracion 1440

    # Media hora de trafico en horario comercial, a ritmo real
    ./generar_trafico.py --url http://<IP_BORDE> --hora-inicio 10 --factor 1 --duracion 1800
"""

import argparse
import json
import random
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter

NOMBRES = ["Camila", "Matias", "Valentina", "Sebastian", "Javiera", "Diego",
           "Antonia", "Cristobal", "Fernanda", "Ignacio", "Josefa", "Benjamin"]
APELLIDOS = ["Rojas", "Munoz", "Soto", "Contreras", "Silva", "Martinez",
             "Vergara", "Fuentes", "Araya", "Espinoza", "Tapia", "Morales"]
SUCURSALES = ["Santiago Centro", "Providencia", "Maipu", "Concepcion", "Vina del Mar"]

detener = threading.Event()
conteo = Counter()
bloqueo = threading.Lock()


def factor_horario(hora: float) -> float:
    """Multiplicador de trafico del sitio publico segun la hora simulada."""
    if hora < 2:
        return 0.15
    if hora < 6:
        return 0.02
    if hora < 9:
        # Incremento progresivo: interpola entre 0.10 y 0.90
        return 0.10 + (hora - 6) / 3 * 0.80
    if hora < 19:
        return 1.00
    if hora < 22:
        return 0.50
    return 0.20


def horario_comercial(hora: float) -> bool:
    """Las sucursales atienden entre 09:00 y 19:00."""
    return 9 <= hora < 19


def persona() -> str:
    return f"{random.choice(NOMBRES)} {random.choice(APELLIDOS)}"


def pedir(url: str, metodo: str = "GET", cuerpo=None, timeout: float = 15.0) -> int:
    datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(url, data=datos, method=metodo)
    if datos:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:
        return 0


def registrar(etiqueta: str, codigo: int) -> None:
    with bloqueo:
        conteo[f"{etiqueta} {codigo or 'sin respuesta'}"] += 1


def visita_publica(base: str) -> None:
    """Lo que hace un visitante del sitio: mirar, y a veces dejar sus datos."""
    sorteo = random.random()
    if sorteo < 0.60:
        registrar("catalogo", pedir(f"{base}/api/catalogo"))
    elif sorteo < 0.80:
        sucursal = random.choice(SUCURSALES).replace(" ", "%20")
        registrar("stock", pedir(f"{base}/stock/api/stock?sucursal={sucursal}"))
    elif sorteo < 0.93:
        registrar("contacto", pedir(f"{base}/api/contacto", "POST", {
            "nombre": persona(),
            "email": "cliente@ejemplo.cl",
            "telefono": "+56 9 1234 5678",
            "vehiculo_id": random.randint(1, 60),
            "monto_clp": random.randrange(8_000_000, 28_000_000, 100_000),
        }))
    else:
        registrar("agendar", pedir(f"{base}/api/agendar", "POST", {
            "nombre": persona(),
            "vehiculo_id": random.randint(1, 60),
            "sucursal": random.choice(SUCURSALES),
            "fecha_visita": "2026-10-15",
        }))


def gestion_comercial(base: str) -> None:
    """Lo que hace un vendedor en el CRM, y el cierre de una venta con pago."""
    sorteo = random.random()
    if sorteo < 0.55:
        registrar("crm_oportunidades", pedir(f"{base}/crm/api/oportunidades"))
    elif sorteo < 0.80:
        registrar("crm_cliente", pedir(f"{base}/crm/api/clientes", "POST", {
            "nombre": persona(), "origen": "sucursal",
        }))
    else:
        monto = random.randrange(8_000_000, 28_000_000, 100_000)
        registrar("pago", pedir(f"{base}/pagos/api/pagos", "POST", {
            "oportunidad_id": random.randint(1, 50), "monto_clp": monto,
        }))


def lanzar(objetivo, base: str) -> None:
    hilo = threading.Thread(target=objetivo, args=(base,), daemon=True)
    hilo.start()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Genera trafico realista contra la plataforma de Andys Motors.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--url", default="http://localhost",
                        help="Entrada publica (HAProxy). Default: http://localhost")
    parser.add_argument("--duracion", type=int, default=600,
                        help="Segundos REALES de ejecucion. Default: 600")
    parser.add_argument("--factor", type=float, default=60.0,
                        help="Aceleracion del tiempo. 60 = 1 minuto real es 1 hora simulada")
    parser.add_argument("--hora-inicio", type=float, default=None,
                        help="Hora simulada de partida (0 a 24). Default: la hora actual")
    parser.add_argument("--rps-peak", type=float, default=8.0,
                        help="Peticiones por segundo en el peak del dia. Default: 8")
    args = parser.parse_args()

    base = args.url.rstrip("/")
    hora = args.hora_inicio if args.hora_inicio is not None else time.localtime().tm_hour

    signal.signal(signal.SIGINT, lambda *_: detener.set())

    print("=" * 64)
    print(" Generador de trafico - Andys Motors")
    print("=" * 64)
    print(f" Destino        : {base}")
    print(f" Duracion real  : {args.duracion}s")
    print(f" Aceleracion    : x{args.factor:g}  ({args.duracion * args.factor / 3600:.1f} horas simuladas)")
    print(f" Hora de inicio : {hora:04.1f}")
    print(f" Peak           : {args.rps_peak:g} req/s")
    print("=" * 64)
    print(" Corta con Ctrl+C en cualquier momento.\n")

    # time.monotonic() y no time.time(): el reloj de pared puede saltar hacia
    # adelante o hacia atras cuando el sistema sincroniza por NTP, cuando la
    # maquina despierta de suspension o dentro de WSL2, y un salto de un minuto
    # cortaria la simulacion de golpe. El reloj monotono solo avanza.
    inicio = time.monotonic()
    ultimo_reporte = 0.0

    # El bucle avanza a un ritmo FIJO y decide cuantas peticiones lanzar en cada
    # tick, en vez de dormir 1/rps. Si durmiera 1/rps, de madrugada (con 0.12
    # req/s) cada espera duraria 8 segundos, y con el tiempo acelerado eso salta
    # varias horas simuladas de golpe: la rampa de las 06:00 a las 09:00
    # desapareceria. El acumulador ademas maneja bien los ritmos fraccionarios.
    TICK = 0.2
    pendientes = 0.0

    while not detener.is_set():
        transcurrido = time.monotonic() - inicio
        if transcurrido >= args.duracion:
            break

        hora_sim = (hora + transcurrido * args.factor / 3600) % 24
        factor = factor_horario(hora_sim)
        rps = max(args.rps_peak * factor, 0.05)

        pendientes += rps * TICK
        while pendientes >= 1.0:
            pendientes -= 1.0

            # Trafico del sitio publico
            lanzar(visita_publica, base)

            # Los sistemas internos solo se usan en horario comercial. Se
            # dispara una gestion comercial cada varias visitas publicas.
            if horario_comercial(hora_sim) and random.random() < 0.35:
                lanzar(gestion_comercial, base)

        if transcurrido - ultimo_reporte >= 5:
            ultimo_reporte = transcurrido
            with bloqueo:
                total = sum(conteo.values())
            print(f"  [{transcurrido:5.0f}s real | {hora_sim:04.1f} simulada] "
                  f"factor {factor:4.2f}  ->  {rps:5.2f} req/s   acumulado: {total}")

        time.sleep(TICK)

    # Espera breve a que terminen las peticiones en vuelo.
    time.sleep(2)

    print("\n" + "=" * 64)
    print(" Resumen por operacion y codigo de respuesta")
    print("=" * 64)
    with bloqueo:
        for clave in sorted(conteo):
            print(f"  {clave:<28} {conteo[clave]:>6}")
        print(f"  {'TOTAL':<28} {sum(conteo.values()):>6}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
