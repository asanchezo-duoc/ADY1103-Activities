// Proveedor externo de procesamiento de pagos.
//
// En el diagrama del caso es el unico componente que NO pertenece a Andys
// Motors. Eso importa: es una dependencia sobre la que la empresa no tiene
// control, no puede instrumentar por dentro y no puede arreglar. Lo unico que
// puede hacer es medirla desde su lado.
//
// No usa base de datos, igual que un proveedor real.

const fallas = require("../lib/fallas");
const logger = require("../lib/logger");
const { contadorNegocio } = require("../lib/metrics");

const autorizaciones = contadorNegocio(
  "autorizaciones_total",
  "Autorizaciones procesadas por el proveedor externo, por resultado.",
  ["resultado"]
);

function rutas(app) {
  app.post("/autorizar", async (req, res) => {
    const { monto_clp } = req.body || {};

    // Latencia base del proveedor: entre 80 y 400 ms en condiciones normales.
    let demora = fallas.entre(80, 400);
    if (fallas.activa("gateway_lento")) {
      demora = fallas.entre(3000, 8000);
    }
    await fallas.esperar(demora);

    // Tasa de rechazo: 4% normal, cerca de la mitad con el escenario activo.
    const tasaRechazo = fallas.activa("gateway_rechazos") ? 0.45 : 0.04;
    const sorteo = Math.random();

    if (sorteo < tasaRechazo) {
      autorizaciones.inc({ resultado: "rechazado" });
      return res.status(402).json({
        estado: "rechazado",
        motivo: "fondos insuficientes o tarjeta invalida",
      });
    }

    // Un 1% de errores del proveedor, que existen siempre en la vida real.
    if (sorteo > 0.99) {
      autorizaciones.inc({ resultado: "error_proveedor" });
      logger.error("el proveedor externo devolvio un error", { request_id: req.requestId });
      return res.status(502).json({ estado: "error", motivo: "error interno del proveedor" });
    }

    autorizaciones.inc({ resultado: "aprobado" });
    res.json({
      estado: "aprobado",
      autorizacion: `AUT-${Math.random().toString(36).slice(2, 10).toUpperCase()}`,
      monto_clp: monto_clp || 0,
    });
  });
}

async function iniciar() {
  // Sin base de datos: un proveedor externo no comparte su almacenamiento.
}

module.exports = { rutas, iniciar };
