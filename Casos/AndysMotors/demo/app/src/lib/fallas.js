// Inyeccion de fallas controlada.
//
// Cada servicio consulta aqui si tiene un escenario activo y cambia su
// comportamiento. Los escenarios se encienden y apagan en caliente por HTTP,
// sin reiniciar nada:
//
//   curl -X POST http://SERVIDOR:8080/admin/fallas \
//        -H "X-Admin-Token: $ANDYS_ADMIN_TOKEN" \
//        -H "Content-Type: application/json" \
//        -d '{"escenario":"agenda_silenciosa","activo":true}'
//
// El escenario mas importante es agenda_silenciosa: la API responde 201, rapido
// y sin errores, pero no guarda nada. Vista desde la infraestructura o desde un
// balanceador, la plataforma esta perfecta. Solo la metrica de negocio revela
// que los agendamientos dejaron de confirmarse.

const logger = require("./logger");

const CATALOGO = {
  agenda_silenciosa: {
    servicio: "agenda",
    descripcion:
      "El agendamiento responde 201 pero no se persiste. Metricas tecnicas sanas, negocio roto.",
  },
  crm_huerfano: {
    servicio: "crm",
    descripcion:
      "El cliente se registra pero la oportunidad no queda vinculada. El vendedor no ve al cliente.",
  },
  stock_desactualizado: {
    servicio: "stock",
    descripcion:
      "El stock responde con datos antiguos. Se ofrecen vehiculos que ya no estan disponibles.",
  },
  gateway_lento: {
    servicio: "gateway",
    descripcion:
      "El proveedor externo de pagos tarda entre 3 y 8 segundos. Dispara la latencia de pagos.",
  },
  gateway_rechazos: {
    servicio: "gateway",
    descripcion:
      "El proveedor externo rechaza cerca de la mitad de las autorizaciones.",
  },
  db_lenta: {
    servicio: "*",
    descripcion:
      "Cada consulta a la base de datos suma entre 300 y 900 ms. Degradacion transversal.",
  },
};

const activos = new Set();

function activa(escenario) {
  return activos.has(escenario);
}

function definir(escenario, activo) {
  if (!CATALOGO[escenario]) {
    return { ok: false, error: `escenario desconocido: ${escenario}` };
  }
  if (activo) {
    activos.add(escenario);
  } else {
    activos.delete(escenario);
  }
  logger.warn("escenario de falla modificado", { escenario, activo });
  return { ok: true, escenario, activo };
}

function estado() {
  return Object.entries(CATALOGO).map(([nombre, meta]) => ({
    escenario: nombre,
    servicio: meta.servicio,
    descripcion: meta.descripcion,
    activo: activos.has(nombre),
  }));
}

// Pausa artificial, usada por los escenarios de lentitud.
function esperar(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Devuelve un numero aleatorio en el rango [min, max).
function entre(min, max) {
  return min + Math.random() * (max - min);
}

module.exports = { CATALOGO, activa, definir, estado, esperar, entre };
