// Registro de metricas Prometheus compartido por todos los servicios.
//
// Se distinguen dos familias, y esa distincion es el corazon de la actividad:
//
//   1. Metricas TECNICAS (RED: Rate, Errors, Duration). Responden "esta el
//      servicio respondiendo, y que tan rapido". Las tiene cualquier servicio
//      HTTP y tambien las ve un balanceador por delante.
//
//   2. Metricas de NEGOCIO. Responden "esta ocurriendo lo que el negocio
//      espera". Un agendamiento confirmado, un pago aprobado. Solo las puede
//      emitir la propia aplicacion: ninguna capa de infraestructura las conoce.
//
// Un servicio puede tener las tecnicas perfectas y las de negocio en el suelo.
// Ese es exactamente el punto ciego que plantea el caso.

const client = require("prom-client");

const SERVICIO = process.env.SERVICIO || "desconocido";

const register = new client.Registry();

// Todas las series de este proceso quedan etiquetadas con el servicio, para
// poder agrupar por plataforma en PromQL con by (servicio).
register.setDefaultLabels({ servicio: SERVICIO });

// Metricas del proceso Node (CPU, memoria, event loop, handles abiertos).
client.collectDefaultMetrics({ register });

// --- 1. Metricas tecnicas (RED) --------------------------------------------

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total de peticiones HTTP atendidas.",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duracion de las peticiones HTTP en segundos.",
  labelNames: ["method", "route", "status_code"],
  // Los buckets definen los percentiles que se pueden calcular despues. Se
  // eligen cubriendo desde respuestas muy rapidas hasta el timeout del
  // proveedor externo de pagos.
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

// Llamadas salientes hacia otras plataformas del caso. Permite reconstruir la
// cadena de dependencias del diagrama a partir de las metricas.
const dependenciaDuration = new client.Histogram({
  name: "dependencia_request_duration_seconds",
  help: "Duracion de las llamadas a otras plataformas de Andys Motors.",
  labelNames: ["destino", "operacion", "resultado"],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

// --- 2. Informacion del servicio -------------------------------------------

new client.Gauge({
  name: "andys_servicio_info",
  help: "Informacion del servicio. El valor siempre es 1: el dato esta en los labels.",
  labelNames: ["version", "plataforma"],
  registers: [register],
}).set({ version: "1.0.0", plataforma: SERVICIO }, 1);

// --- Helpers ---------------------------------------------------------------

// Crea un contador de negocio ya registrado, para no repetir el registro en
// cada servicio.
function contadorNegocio(name, help, labelNames = []) {
  return new client.Counter({ name, help, labelNames, registers: [register] });
}

function medidorNegocio(name, help, labelNames = []) {
  return new client.Gauge({ name, help, labelNames, registers: [register] });
}

module.exports = {
  client,
  register,
  httpRequestsTotal,
  httpRequestDuration,
  dependenciaDuration,
  contadorNegocio,
  medidorNegocio,
};
