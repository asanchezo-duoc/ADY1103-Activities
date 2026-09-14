// Sistema de pagos.
//
// Genera la orden de pago, la manda a autorizar al proveedor externo y deja el
// resultado en la base de datos. Es el proceso transaccional mas critico del
// caso: si falla, no se cierra la venta.
//
// Depende de dos cosas que no controla del todo (la base de datos y el
// proveedor externo), asi que es el mejor lugar para ver la diferencia entre
// "yo estoy lento" y "de quien dependo esta lento": la metrica
// dependencia_request_duration_seconds separa exactamente eso.

const db = require("../lib/db");
const cliente = require("../lib/cliente");
const logger = require("../lib/logger");
const { contadorNegocio } = require("../lib/metrics");

const GATEWAY_HOST = process.env.GATEWAY_HOST || "gateway-externo";
const GATEWAY_PORT = Number(process.env.GATEWAY_PORT || 8080);

const pagosTotal = contadorNegocio(
  "pagos_total",
  "Pagos procesados, por resultado final.",
  ["resultado"]
);

const montoTransado = contadorNegocio(
  "monto_transado_clp_total",
  "Monto acumulado de pagos aprobados, en pesos chilenos."
);

function rutas(app) {
  app.post("/api/pagos", async (req, res) => {
    const { oportunidad_id, monto_clp } = req.body || {};
    if (!monto_clp) return res.status(400).json({ error: "falta monto_clp" });

    const respuesta = await cliente.llamar({
      destino: "gateway-externo",
      operacion: "autorizar",
      host: GATEWAY_HOST,
      puerto: GATEWAY_PORT,
      ruta: "/autorizar",
      metodo: "POST",
      cuerpo: { monto_clp },
      requestId: req.requestId,
    });

    let estado = "error";
    let autorizacion = null;

    if (respuesta.ok && respuesta.datos && respuesta.datos.estado === "aprobado") {
      estado = "aprobado";
      autorizacion = respuesta.datos.autorizacion;
    } else if (respuesta.status === 402) {
      estado = "rechazado";
    }

    try {
      await db.consultar(
        `INSERT INTO pagos (oportunidad_id, monto_clp, estado, autorizacion)
         VALUES ($1, $2, $3, $4)`,
        [oportunidad_id || null, monto_clp, estado, autorizacion]
      );
    } catch (err) {
      logger.error("el pago no se pudo registrar en la base de datos", {
        error: err.message,
        request_id: req.requestId,
        estado,
      });
    }

    pagosTotal.inc({ resultado: estado });
    if (estado === "aprobado") montoTransado.inc(Number(monto_clp));

    const codigoHttp = estado === "aprobado" ? 201 : estado === "rechazado" ? 402 : 502;
    res.status(codigoHttp).json({ estado, autorizacion, monto_clp });
  });

  app.get("/api/pagos", async (req, res) => {
    try {
      const filas = await db.consultar(
        `SELECT id, oportunidad_id, monto_clp, estado, creado_en
           FROM pagos ORDER BY creado_en DESC LIMIT 50`
      );
      res.json({ total: filas.length, pagos: filas });
    } catch (err) {
      res.status(500).json({ error: "no se pudieron listar los pagos" });
    }
  });
}

async function iniciar() {
  await db.inicializar();
}

module.exports = { rutas, iniciar };
