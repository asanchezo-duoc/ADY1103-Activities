// Sitio web publico.
//
// Es la cara visible del negocio, y el unico servicio al que llegan clientes
// finales. No vende: permite consultar vehiculos, revisar disponibilidad,
// solicitar contacto y agendar visitas, tal como describe el caso.
//
// No tiene base de datos propia: todo lo resuelve llamando a otras plataformas.
// Por eso es el mejor punto para observar como una falla en una dependencia se
// propaga hacia el cliente final.

const cliente = require("../lib/cliente");
const logger = require("../lib/logger");
const { contadorNegocio } = require("../lib/metrics");

const destinos = {
  stock: {
    host: process.env.STOCK_HOST || "stock-api",
    puerto: Number(process.env.STOCK_PORT || 8080),
  },
  agenda: {
    host: process.env.AGENDA_HOST || "agenda-api",
    puerto: Number(process.env.AGENDA_PORT || 8080),
  },
  crm: {
    host: process.env.CRM_HOST || "crm-api",
    puerto: Number(process.env.CRM_PORT || 8080),
  },
};

const solicitudesContacto = contadorNegocio(
  "solicitudes_contacto_total",
  "Solicitudes de contacto enviadas desde el sitio publico, por resultado.",
  ["resultado"]
);

const visitasAgendadas = contadorNegocio(
  "visitas_agendadas_sitio_total",
  "Visitas agendadas a traves del sitio publico, por resultado.",
  ["resultado"]
);

function rutas(app) {
  app.get("/", (req, res) => {
    res.json({
      empresa: "Andys Motors",
      mensaje: "Sitio web publico: catalogo, stock, contacto y agendamiento de visitas",
      endpoints: [
        "GET  /api/catalogo",
        "POST /api/contacto",
        "POST /api/agendar",
        "GET  /health",
        "GET  /metrics",
      ],
    });
  });

  // Catalogo: el sitio no tiene los datos, se los pide a la plataforma de stock.
  app.get("/api/catalogo", async (req, res) => {
    const query = req.query.sucursal ? `?sucursal=${encodeURIComponent(req.query.sucursal)}` : "";
    const respuesta = await cliente.llamar({
      destino: "stock-api",
      operacion: "consultar_stock",
      host: destinos.stock.host,
      puerto: destinos.stock.puerto,
      ruta: `/api/stock${query}`,
      requestId: req.requestId,
    });

    if (!respuesta.ok) {
      return res.status(503).json({ error: "el catalogo no esta disponible en este momento" });
    }
    res.json(respuesta.datos);
  });

  // Solicitud de contacto: crea el cliente en el CRM y le abre una oportunidad.
  app.post("/api/contacto", async (req, res) => {
    const { nombre, email, telefono, vehiculo_id, monto_clp } = req.body || {};
    if (!nombre) {
      solicitudesContacto.inc({ resultado: "invalido" });
      return res.status(400).json({ error: "falta nombre" });
    }

    const alta = await cliente.llamar({
      destino: "crm-api",
      operacion: "crear_cliente",
      host: destinos.crm.host,
      puerto: destinos.crm.puerto,
      ruta: "/api/clientes",
      metodo: "POST",
      cuerpo: { nombre, email, telefono, origen: "sitio_web" },
      requestId: req.requestId,
    });

    if (!alta.ok) {
      solicitudesContacto.inc({ resultado: "error" });
      return res.status(503).json({ error: "no se pudo registrar la solicitud de contacto" });
    }

    // La oportunidad comercial es lo que despues trabaja el vendedor.
    await cliente.llamar({
      destino: "crm-api",
      operacion: "crear_oportunidad",
      host: destinos.crm.host,
      puerto: destinos.crm.puerto,
      ruta: "/api/oportunidades",
      metodo: "POST",
      cuerpo: { cliente_id: alta.datos && alta.datos.id, vehiculo_id, monto_clp },
      requestId: req.requestId,
    });

    solicitudesContacto.inc({ resultado: "ok" });
    res.status(201).json({ estado: "recibido", cliente: alta.datos });
  });

  // Agendamiento de visita a la sucursal.
  app.post("/api/agendar", async (req, res) => {
    const { nombre, vehiculo_id, sucursal, fecha_visita } = req.body || {};
    if (!nombre || !fecha_visita) {
      visitasAgendadas.inc({ resultado: "invalido" });
      return res.status(400).json({ error: "faltan nombre o fecha_visita" });
    }

    const respuesta = await cliente.llamar({
      destino: "agenda-api",
      operacion: "crear_agendamiento",
      host: destinos.agenda.host,
      puerto: destinos.agenda.puerto,
      ruta: "/api/agendamientos",
      metodo: "POST",
      cuerpo: { cliente_nombre: nombre, vehiculo_id, sucursal, fecha_visita },
      requestId: req.requestId,
    });

    if (!respuesta.ok) {
      visitasAgendadas.inc({ resultado: "error" });
      logger.error("no se pudo agendar la visita", {
        request_id: req.requestId,
        status: respuesta.status,
      });
      return res.status(503).json({ error: "no se pudo agendar la visita" });
    }

    // Nota importante para la actividad: el sitio web cuenta esto como "ok"
    // porque la plataforma de agendamiento respondio 201. Si esa plataforma
    // esta descartando los agendamientos en silencio, este contador tampoco se
    // entera. La verdad solo esta en agendamientos_confirmados_total.
    visitasAgendadas.inc({ resultado: "ok" });
    res.status(201).json({ estado: "agendado", detalle: respuesta.datos });
  });
}

async function iniciar() {
  // El sitio publico no abre conexion a la base de datos: depende de las otras
  // plataformas, igual que en el diagrama del caso.
}

module.exports = { rutas, iniciar };
