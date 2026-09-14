// Logs estructurados en JSON, una linea por evento, hacia stdout.
//
// Se usa JSON y no texto libre porque asi un recolector de logs (CloudWatch
// Logs, Loki, Elastic) puede filtrar por campo sin tener que adivinar con
// expresiones regulares. Es la diferencia entre un log que se lee y un log
// que se consulta.

const SERVICIO = process.env.SERVICIO || "desconocido";

function emitir(nivel, mensaje, datos = {}) {
  const linea = {
    ts: new Date().toISOString(),
    nivel,
    servicio: SERVICIO,
    mensaje,
    ...datos,
  };
  // Un console.log por linea: los contenedores escriben a stdout y el runtime
  // se encarga de recolectarlo.
  console.log(JSON.stringify(linea));
}

module.exports = {
  info: (mensaje, datos) => emitir("info", mensaje, datos),
  warn: (mensaje, datos) => emitir("warn", mensaje, datos),
  error: (mensaje, datos) => emitir("error", mensaje, datos),
};
