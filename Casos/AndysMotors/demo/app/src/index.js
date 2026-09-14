// Punto de entrada unico de las seis plataformas de Andys Motors.
//
// El servicio concreto se elige con la variable de entorno SERVICIO. Asi se
// construye una sola imagen y se despliega con distinta configuracion en cada
// servidor, que es como se reparte el caso entre maquinas.

const { crearApp, arrancar, SERVICIO } = require("./lib/servidor");
const logger = require("./lib/logger");

const SERVICIOS = {
  web: "./servicios/web",
  stock: "./servicios/stock",
  agenda: "./servicios/agenda",
  crm: "./servicios/crm",
  pagos: "./servicios/pagos",
  gateway: "./servicios/gateway",
};

async function main() {
  const ruta = SERVICIOS[SERVICIO];
  if (!ruta) {
    console.error(
      `SERVICIO invalido: "${SERVICIO}". Valores validos: ${Object.keys(SERVICIOS).join(", ")}`
    );
    process.exit(1);
  }

  const servicio = require(ruta);
  const app = crearApp(servicio.rutas);

  // Los servicios que usan base de datos esperan a que este disponible. En un
  // despliegue con varios servidores, la base puede tardar mas en arrancar que
  // las aplicaciones, asi que se reintenta en vez de morir en el primer fallo.
  const MAX_INTENTOS = 30;
  for (let intento = 1; intento <= MAX_INTENTOS; intento++) {
    try {
      await servicio.iniciar();
      break;
    } catch (err) {
      if (intento === MAX_INTENTOS) {
        logger.error("no se pudo inicializar el servicio", { error: err.message });
        process.exit(1);
      }
      logger.warn("dependencia no disponible todavia, reintentando", {
        intento,
        error: err.message,
      });
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  arrancar(app);
}

main();
