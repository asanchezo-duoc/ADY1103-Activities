// Logs estructurados en JSON, una linea por evento, hacia stdout.
//
// Se usa JSON y no texto libre porque asi un recolector de logs (CloudWatch
// Logs, Loki, Elastic) puede filtrar por campo sin tener que adivinar con
// expresiones regulares. Es la diferencia entre un log que se lee y un log
// que se consulta.

const fs = require("fs");
const path = require("path");

const SERVICIO = process.env.SERVICIO || "desconocido";

// Si LOG_DIR esta definido, cada linea se escribe ademas en
// LOG_DIR/<servicio>.log. Asi un agente instalado en el host (por ejemplo el
// CloudWatch Agent) lee los logs desde un archivo, montando esa carpeta como
// volumen. Sin LOG_DIR, todo sigue yendo solo a stdout.
// Si el archivo falla (permisos, disco lleno), se deja de escribir en el,
// pero el servicio sigue funcionando y logueando a stdout.
let archivo = null;

function avisarFalloArchivo(err) {
  console.error(JSON.stringify({ ts: new Date().toISOString(), nivel: "error", servicio: SERVICIO, mensaje: "no se pudo escribir el archivo de log", error: err.message }));
  archivo = null;
}

if (process.env.LOG_DIR) {
  try {
    fs.mkdirSync(process.env.LOG_DIR, { recursive: true });
    archivo = fs.createWriteStream(path.join(process.env.LOG_DIR, `${SERVICIO}.log`), { flags: "a" });
    archivo.on("error", avisarFalloArchivo);
  } catch (err) {
    avisarFalloArchivo(err);
  }
}

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
  const texto = JSON.stringify(linea);
  console.log(texto);
  if (archivo) archivo.write(texto + "\n");
}

module.exports = {
  info: (mensaje, datos) => emitir("info", mensaje, datos),
  warn: (mensaje, datos) => emitir("warn", mensaje, datos),
  error: (mensaje, datos) => emitir("error", mensaje, datos),
};
