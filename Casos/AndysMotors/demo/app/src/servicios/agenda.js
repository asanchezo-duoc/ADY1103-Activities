// Sistema de agendamiento de visitas.
//
// Esta es la plataforma donde vive el escenario mas importante del caso.
//
// Con agenda_silenciosa activo, la API sigue respondiendo 201 Created, rapido y
// sin errores: CPU normal, memoria normal, latencia normal, cero 5xx. Un
// balanceador por delante muestra todo verde. Pero el agendamiento nunca llega
// a la base de datos.
//
// La unica senal esta en la distancia entre dos contadores de negocio:
//
//   agendamientos_solicitados_total   sigue subiendo
//   agendamientos_confirmados_total   se queda plano
//
// Ese hueco es lo que ninguna metrica de infraestructura puede ver.

const db = require("../lib/db");
const fallas = require("../lib/fallas");
const logger = require("../lib/logger");
const { contadorNegocio } = require("../lib/metrics");

const solicitados = contadorNegocio(
  "agendamientos_solicitados_total",
  "Agendamientos de visita solicitados por los clientes.",
  ["sucursal"]
);

const confirmados = contadorNegocio(
  "agendamientos_confirmados_total",
  "Agendamientos de visita efectivamente registrados en la base de datos.",
  ["sucursal"]
);

function rutas(app) {
  app.post("/api/agendamientos", async (req, res) => {
    const { cliente_nombre, vehiculo_id, sucursal, fecha_visita } = req.body || {};
    const suc = sucursal || "Santiago Centro";

    if (!cliente_nombre || !fecha_visita) {
      return res.status(400).json({ error: "faltan cliente_nombre o fecha_visita" });
    }

    solicitados.inc({ sucursal: suc });

    if (fallas.activa("agenda_silenciosa")) {
      // Se responde exactamente igual que en el camino feliz, pero sin escribir.
      // El log queda como unica pista dentro del servicio.
      logger.warn("agendamiento descartado sin persistir", {
        request_id: req.requestId,
        cliente_nombre,
        sucursal: suc,
      });
      return res.status(201).json({
        id: Math.floor(Math.random() * 100000),
        estado: "confirmado",
        sucursal: suc,
        fecha_visita,
      });
    }

    try {
      const filas = await db.consultar(
        `INSERT INTO agendamientos (cliente_nombre, vehiculo_id, sucursal, fecha_visita)
         VALUES ($1, $2, $3, $4) RETURNING id, estado, sucursal, fecha_visita`,
        [cliente_nombre, vehiculo_id || null, suc, fecha_visita]
      );
      confirmados.inc({ sucursal: suc });
      res.status(201).json(filas[0]);
    } catch (err) {
      logger.error("fallo al registrar el agendamiento", {
        error: err.message,
        request_id: req.requestId,
      });
      res.status(500).json({ error: "no se pudo registrar el agendamiento" });
    }
  });

  app.get("/api/agendamientos", async (req, res) => {
    try {
      const filas = await db.consultar(
        `SELECT id, cliente_nombre, sucursal, fecha_visita, estado, creado_en
           FROM agendamientos ORDER BY creado_en DESC LIMIT 50`
      );
      res.json({ total: filas.length, agendamientos: filas });
    } catch (err) {
      res.status(500).json({ error: "no se pudieron listar los agendamientos" });
    }
  });
}

async function iniciar() {
  await db.inicializar();
}

module.exports = { rutas, iniciar };
