// Armado comun de todos los servicios: middleware de metricas y logs, los
// endpoints /health, /metrics y /admin/fallas, y el arranque del servidor.
//
// Cada plataforma del caso solo aporta sus rutas de negocio; todo lo que tiene
// que ver con observabilidad vive aqui y es identico en los seis servicios.

const express = require("express");
const crypto = require("crypto");

const { register, httpRequestsTotal, httpRequestDuration } = require("./metrics");
const logger = require("./logger");
const fallas = require("./fallas");

const SERVICIO = process.env.SERVICIO || "desconocido";
const PORT = Number(process.env.PORT || 8080);
const ADMIN_TOKEN = process.env.ANDYS_ADMIN_TOKEN || "andys-lab";

// Evita que los identificadores en la URL exploten la cardinalidad de labels.
// Sin esto, /api/stock/42 y /api/stock/43 serian dos series distintas, y con
// mil vehiculos Prometheus terminaria guardando mil series por endpoint.
function normalizarRuta(req) {
  if (req.route && req.baseUrl !== undefined) return req.baseUrl + req.route.path;
  return req.path.replace(/\/\d+(?=\/|$)/g, "/:id");
}

function crearApp(configurarRutas) {
  const app = express();
  app.use(express.json());

  // --- Middleware de observabilidad ---------------------------------------
  app.use((req, res, next) => {
    const inicio = process.hrtime.bigint();
    // Se reutiliza el id que venga de aguas arriba; si no hay, se crea uno.
    req.requestId = req.get("x-request-id") || crypto.randomUUID();
    res.set("x-request-id", req.requestId);

    res.on("finish", () => {
      const duracionSegundos = Number(process.hrtime.bigint() - inicio) / 1e9;
      const etiquetas = {
        method: req.method,
        route: normalizarRuta(req),
        status_code: res.statusCode,
      };
      httpRequestsTotal.inc(etiquetas);
      httpRequestDuration.observe(etiquetas, duracionSegundos);

      logger.info("peticion atendida", {
        metodo: req.method,
        ruta: etiquetas.route,
        status: res.statusCode,
        duracion_ms: Math.round(duracionSegundos * 1000),
        request_id: req.requestId,
      });
    });

    next();
  });

  // --- Endpoints comunes ---------------------------------------------------

  // /health responde si el PROCESO esta vivo. Ojo: que responda 200 no
  // significa que el negocio funcione. Esa distincion es el tema del caso.
  app.get("/health", (req, res) => {
    res.json({
      status: "ok",
      servicio: SERVICIO,
      uptime_segundos: Math.round(process.uptime()),
    });
  });

  app.get("/metrics", async (req, res) => {
    res.set("Content-Type", register.contentType);
    res.end(await register.metrics());
  });

  // --- Panel de inyeccion de fallas ---------------------------------------
  function exigirToken(req, res, next) {
    if (req.get("x-admin-token") !== ADMIN_TOKEN) {
      return res.status(401).json({ error: "token de administracion invalido" });
    }
    next();
  }

  app.get("/admin/fallas", exigirToken, (req, res) => {
    res.json({ servicio: SERVICIO, escenarios: fallas.estado() });
  });

  app.post("/admin/fallas", exigirToken, (req, res) => {
    const { escenario, activo } = req.body || {};
    if (typeof escenario !== "string" || typeof activo !== "boolean") {
      return res
        .status(400)
        .json({ error: 'se espera {"escenario": "nombre", "activo": true|false}' });
    }
    const resultado = fallas.definir(escenario, activo);
    res.status(resultado.ok ? 200 : 400).json(resultado);
  });

  // --- Rutas de negocio del servicio concreto ------------------------------
  configurarRutas(app);

  app.use((req, res) => {
    res.status(404).json({ error: "ruta no encontrada", ruta: req.path });
  });

  return app;
}

function arrancar(app) {
  app.listen(PORT, () => {
    logger.info("servicio escuchando", { puerto: PORT });
  });
}

module.exports = { crearApp, arrancar, SERVICIO, PORT };
