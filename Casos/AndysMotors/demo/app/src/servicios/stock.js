// Sistema de consulta de stock de vehiculos.
//
// Es la plataforma de solo lectura del caso: responde que hay disponible y en
// que sucursal. La usa el sitio web publico para armar el catalogo.

const db = require("../lib/db");
const fallas = require("../lib/fallas");
const logger = require("../lib/logger");
const { contadorNegocio, medidorNegocio } = require("../lib/metrics");

const consultasStock = contadorNegocio(
  "consultas_stock_total",
  "Consultas de stock atendidas, por resultado.",
  ["resultado", "sucursal"]
);

const vehiculosDisponibles = medidorNegocio(
  "vehiculos_disponibles",
  "Vehiculos marcados como disponibles, por sucursal y condicion.",
  ["sucursal", "condicion"]
);

// Cache usada por el escenario stock_desactualizado: guarda la primera
// respuesta y la sigue devolviendo aunque el inventario real cambie.
let cacheRancia = null;

async function refrescarInventario() {
  const filas = await db.consultar(
    `SELECT sucursal, condicion, COUNT(*)::int AS total
       FROM vehiculos WHERE disponible = true
      GROUP BY sucursal, condicion`
  );
  vehiculosDisponibles.reset();
  for (const fila of filas) {
    vehiculosDisponibles.set(
      { sucursal: fila.sucursal, condicion: fila.condicion },
      fila.total
    );
  }
}

function rutas(app) {
  app.get("/api/stock", async (req, res) => {
    const sucursal = req.query.sucursal || "todas";
    try {
      if (fallas.activa("stock_desactualizado") && cacheRancia) {
        // Responde rapido y con 200: desde afuera no se distingue de una
        // respuesta correcta. Solo el contenido esta equivocado.
        consultasStock.inc({ resultado: "ok", sucursal });
        return res.json({ ...cacheRancia, advertencia_interna: "respuesta desde cache" });
      }

      const params = [];
      let sql = `SELECT id, marca, modelo, anio, condicion, precio_clp, sucursal
                   FROM vehiculos WHERE disponible = true`;
      if (req.query.sucursal) {
        params.push(req.query.sucursal);
        sql += ` AND sucursal = $1`;
      }
      sql += ` ORDER BY precio_clp LIMIT 20`;

      const vehiculos = await db.consultar(sql, params);
      const respuesta = { total: vehiculos.length, vehiculos };
      cacheRancia = respuesta;

      consultasStock.inc({ resultado: "ok", sucursal });
      res.json(respuesta);
    } catch (err) {
      consultasStock.inc({ resultado: "error", sucursal });
      logger.error("fallo la consulta de stock", { error: err.message, request_id: req.requestId });
      res.status(500).json({ error: "no se pudo consultar el stock" });
    }
  });

  app.get("/api/stock/:id", async (req, res) => {
    try {
      const filas = await db.consultar("SELECT * FROM vehiculos WHERE id = $1", [req.params.id]);
      if (filas.length === 0) {
        consultasStock.inc({ resultado: "no_encontrado", sucursal: "todas" });
        return res.status(404).json({ error: "vehiculo no encontrado" });
      }
      consultasStock.inc({ resultado: "ok", sucursal: filas[0].sucursal });
      res.json(filas[0]);
    } catch (err) {
      consultasStock.inc({ resultado: "error", sucursal: "todas" });
      res.status(500).json({ error: "no se pudo consultar el vehiculo" });
    }
  });
}

async function iniciar() {
  await db.inicializar();
  await refrescarInventario();
  // El inventario se recalcula periodicamente: es un gauge, no un contador.
  setInterval(() => refrescarInventario().catch(() => {}), 30000);
}

module.exports = { rutas, iniciar };
