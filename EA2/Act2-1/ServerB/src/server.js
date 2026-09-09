// ServerB - API de ejemplo a monitorear.
//
// Endpoints:
//   GET /health          -> chequeo de salud (usado por el propio Docker HEALTHCHECK)
//   GET /api/saludo      -> endpoint de ejemplo 1
//   GET /api/productos   -> endpoint de ejemplo 2
//   GET /api/error       -> siempre responde 500 (para probar el panel de errores)
//   GET /api/random      -> responde 200/404/500 al azar (para simular trafico real)
//   GET /metrics         -> metricas en formato Prometheus (texto plano)
//
// Prometheus (ServerA) hace "pull" de este endpoint /metrics cada scrape_interval.
//
// /api/error y /api/random existen solo para generar datos de prueba en los
// dashboards (tasa de errores, requests por status code). Ver scripts/generate_traffic.py
// en Act2-1 para un generador de carga que las usa automaticamente.

const express = require("express");
const client = require("prom-client");

const app = express();
const PORT = process.env.PORT || 8080;

// --- Metricas Prometheus -----------------------------------------------
// Registro por defecto de prom-client: junta metricas propias del proceso
// (CPU, memoria, event loop, etc), utiles para ver la salud del contenedor.
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// Metrica custom #1: contador de requests HTTP, con labels de metodo/ruta/status.
// Un contador solo puede subir; sirve para calcular tasas (rate) en Grafana.
const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Cantidad total de requests HTTP recibidas",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// Metrica custom #2: histograma de duracion de requests, en segundos.
// Un histograma permite calcular percentiles (p50/p95/p99) en Grafana.
const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duracion de las requests HTTP en segundos",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [register],
});

// Middleware que mide cada request y actualiza las metricas de arriba.
app.use((req, res, next) => {
  const endTimer = httpRequestDuration.startTimer();
  res.on("finish", () => {
    // req.route.path solo existe si la ruta hizo match; si no, se usa la url cruda.
    const route = req.route ? req.route.path : req.path;
    const labels = { method: req.method, route, status_code: res.statusCode };
    httpRequestsTotal.inc(labels);
    endTimer(labels);
  });
  next();
});

// --- Health check --------------------------------------------------------
app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok", uptime_seconds: process.uptime() });
});

// --- Endpoints de ejemplo --------------------------------------------------
app.get("/api/saludo", (req, res) => {
  res.status(200).json({ mensaje: "Hola desde ServerB!" });
});

app.get("/api/productos", (req, res) => {
  // Datos de ejemplo hardcodeados; los alumnos pueden reemplazar esto por
  // llamadas a una base de datos real.
  res.status(200).json({
    productos: [
      { id: 1, nombre: "Producto A", precio: 1000 },
      { id: 2, nombre: "Producto B", precio: 2000 },
    ],
  });
});

// --- Endpoints para generar datos de prueba en los dashboards ---------------
app.get("/api/error", (req, res) => {
  // Siempre falla: util para ver el panel "Tasa de errores (5xx)" moverse.
  res.status(500).json({ error: "Error simulado para pruebas de monitoreo" });
});

app.get("/api/random", (req, res) => {
  // Simula un endpoint real: la mayoria de las veces responde bien, pero a
  // veces devuelve 404 (recurso no encontrado) o 500 (falla del servidor).
  const roll = Math.random();
  if (roll < 0.05) {
    res.status(500).json({ error: "Fallo aleatorio simulado" });
  } else if (roll < 0.15) {
    res.status(404).json({ error: "Recurso no encontrado (simulado)" });
  } else {
    res.status(200).json({ mensaje: "OK" });
  }
});

// --- Endpoint de metricas para Prometheus ---------------------------------
app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

app.listen(PORT, () => {
  console.log(`ServerB escuchando en el puerto ${PORT}`);
});
