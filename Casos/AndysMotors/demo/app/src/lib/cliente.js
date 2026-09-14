// Cliente HTTP para hablar con las otras plataformas de Andys Motors.
//
// Hace tres cosas que importan para la observabilidad:
//
//   1. Mide cada llamada saliente en dependencia_request_duration_seconds. Asi
//      se puede distinguir "mi servicio esta lento" de "el servicio del que
//      dependo esta lento", que es la pregunta mas frecuente en un incidente.
//
//   2. Propaga la cabecera x-request-id. Si una peticion entra por el sitio
//      web, llama a stock y despues a agenda, las tres dejan el MISMO id en sus
//      logs. Eso permite reconstruir el recorrido completo: es una traza pobre,
//      pero es una traza.
//
//   3. Aplica timeout. Sin timeout, una dependencia colgada arrastra a quien la
//      llama hasta agotarle las conexiones.

const http = require("http");
const { dependenciaDuration } = require("./metrics");
const logger = require("./logger");

const TIMEOUT_MS = Number(process.env.DEPENDENCIA_TIMEOUT_MS || 10000);

function llamar({ destino, operacion, host, puerto, ruta, metodo = "GET", cuerpo = null, requestId }) {
  const finTimer = dependenciaDuration.startTimer({ destino, operacion });
  const datos = cuerpo ? JSON.stringify(cuerpo) : null;

  return new Promise((resolve) => {
    const req = http.request(
      {
        host,
        port: puerto,
        path: ruta,
        method: metodo,
        timeout: TIMEOUT_MS,
        headers: {
          "Content-Type": "application/json",
          "x-request-id": requestId || "",
          ...(datos ? { "Content-Length": Buffer.byteLength(datos) } : {}),
        },
      },
      (res) => {
        let buffer = "";
        res.on("data", (trozo) => (buffer += trozo));
        res.on("end", () => {
          const resultado = res.statusCode < 400 ? "ok" : "error";
          finTimer({ resultado });
          let json = null;
          try {
            json = buffer ? JSON.parse(buffer) : null;
          } catch (_) {
            json = null;
          }
          resolve({ ok: resultado === "ok", status: res.statusCode, datos: json });
        });
      }
    );

    req.on("timeout", () => {
      finTimer({ resultado: "timeout" });
      logger.error("timeout llamando a una dependencia", { destino, operacion, request_id: requestId });
      req.destroy();
      resolve({ ok: false, status: 504, datos: null, error: "timeout" });
    });

    req.on("error", (err) => {
      finTimer({ resultado: "error_red" });
      logger.error("error de red llamando a una dependencia", {
        destino,
        operacion,
        error: err.message,
        request_id: requestId,
      });
      resolve({ ok: false, status: 502, datos: null, error: err.message });
    });

    if (datos) req.write(datos);
    req.end();
  });
}

module.exports = { llamar };
