// CRM / Sistema de ventas.
//
// Es la plataforma interna del caso: la usan los vendedores para gestionar
// clientes, oportunidades y ventas. Su criticidad es maxima en horario
// comercial (09:00 a 19:00) y practicamente nula de madrugada, lo que despues
// justifica tener un SLA distinto por franja horaria.
//
// Escenario crm_huerfano: el cliente se registra, pero la oportunidad queda sin
// vincular. El vendedor "no ve al cliente en el CRM", que es literalmente el
// sintoma que reportan los vendedores en el caso.

const db = require("../lib/db");
const fallas = require("../lib/fallas");
const logger = require("../lib/logger");
const { contadorNegocio } = require("../lib/metrics");

const clientesRegistrados = contadorNegocio(
  "clientes_registrados_total",
  "Clientes dados de alta en el CRM.",
  ["origen"]
);

const oportunidadesCreadas = contadorNegocio(
  "oportunidades_creadas_total",
  "Oportunidades comerciales creadas."
);

const oportunidadesVinculadas = contadorNegocio(
  "oportunidades_vinculadas_total",
  "Oportunidades que quedaron correctamente asociadas a un cliente."
);

const ventasCerradas = contadorNegocio(
  "ventas_cerradas_total",
  "Ventas cerradas por los ejecutivos comerciales.",
  ["sucursal"]
);

const montoVendido = contadorNegocio(
  "monto_vendido_clp_total",
  "Monto acumulado de ventas cerradas, en pesos chilenos.",
  ["sucursal"]
);

function rutas(app) {
  app.post("/api/clientes", async (req, res) => {
    const { nombre, email, telefono, origen } = req.body || {};
    if (!nombre) return res.status(400).json({ error: "falta nombre" });

    try {
      const filas = await db.consultar(
        `INSERT INTO clientes (nombre, email, telefono, origen)
         VALUES ($1, $2, $3, $4) RETURNING id, nombre, origen, creado_en`,
        [nombre, email || null, telefono || null, origen || "sitio_web"]
      );
      clientesRegistrados.inc({ origen: origen || "sitio_web" });
      res.status(201).json(filas[0]);
    } catch (err) {
      logger.error("fallo al registrar el cliente", {
        error: err.message,
        request_id: req.requestId,
      });
      res.status(500).json({ error: "no se pudo registrar el cliente" });
    }
  });

  app.post("/api/oportunidades", async (req, res) => {
    const { cliente_id, vehiculo_id, monto_clp } = req.body || {};
    oportunidadesCreadas.inc();

    try {
      // Con crm_huerfano activo la oportunidad se crea SIN cliente asociado.
      // La respuesta es 201 y la latencia identica: por fuera no se nota.
      const clienteAsociado = fallas.activa("crm_huerfano") ? null : cliente_id || null;

      const filas = await db.consultar(
        `INSERT INTO oportunidades (cliente_id, vehiculo_id, monto_clp)
         VALUES ($1, $2, $3) RETURNING id, cliente_id, etapa, monto_clp`,
        [clienteAsociado, vehiculo_id || null, monto_clp || null]
      );

      if (clienteAsociado) {
        oportunidadesVinculadas.inc();
      } else {
        logger.warn("oportunidad creada sin cliente asociado", {
          request_id: req.requestId,
          oportunidad_id: filas[0].id,
        });
      }

      res.status(201).json(filas[0]);
    } catch (err) {
      res.status(500).json({ error: "no se pudo crear la oportunidad" });
    }
  });

  app.get("/api/oportunidades", async (req, res) => {
    try {
      // Un LEFT JOIN deja ver el problema: con crm_huerfano activo, las
      // oportunidades aparecen con cliente en null.
      const filas = await db.consultar(
        `SELECT o.id, o.etapa, o.monto_clp, c.nombre AS cliente
           FROM oportunidades o
           LEFT JOIN clientes c ON c.id = o.cliente_id
          ORDER BY o.creado_en DESC LIMIT 50`
      );
      res.json({ total: filas.length, oportunidades: filas });
    } catch (err) {
      res.status(500).json({ error: "no se pudieron listar las oportunidades" });
    }
  });

  app.post("/api/ventas", async (req, res) => {
    const { oportunidad_id, monto_clp, sucursal } = req.body || {};
    const suc = sucursal || "Santiago Centro";
    if (!monto_clp) return res.status(400).json({ error: "falta monto_clp" });

    try {
      await db.consultar(`UPDATE oportunidades SET etapa = 'cerrada' WHERE id = $1`, [
        oportunidad_id || null,
      ]);
      ventasCerradas.inc({ sucursal: suc });
      montoVendido.inc({ sucursal: suc }, Number(monto_clp));
      res.status(201).json({ oportunidad_id, monto_clp, sucursal: suc, etapa: "cerrada" });
    } catch (err) {
      res.status(500).json({ error: "no se pudo cerrar la venta" });
    }
  });
}

async function iniciar() {
  await db.inicializar();
}

module.exports = { rutas, iniciar };
