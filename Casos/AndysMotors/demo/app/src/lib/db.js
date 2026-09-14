// Acceso a la base de datos central (Amazon RDS o el contenedor PostgreSQL).
//
// Solo los servicios que realmente persisten datos abren la conexion: web y
// gateway no tocan la base. Eso importa para el caso, porque la cadena de
// dependencias que se ve en las metricas debe reflejar el diagrama.

const { Pool } = require("pg");
const logger = require("./logger");
const fallas = require("./fallas");

let pool = null;

function obtenerPool() {
  if (pool) return pool;

  pool = new Pool({
    host: process.env.DB_HOST || "postgres",
    port: Number(process.env.DB_PORT || 5432),
    database: process.env.DB_NAME || "andysmotors",
    user: process.env.DB_USER || "andysadmin",
    password: process.env.DB_PASSWORD || "cambiame",
    // Un pool chico a proposito: con 5 conexiones, una consulta lenta se nota
    // como espera en cola, que es justamente lo que se quiere poder observar.
    max: Number(process.env.DB_POOL_MAX || 5),
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
  });

  pool.on("error", (err) => {
    logger.error("error inesperado en el pool de conexiones", { error: err.message });
  });

  return pool;
}

async function consultar(sql, params = []) {
  // Escenario db_lenta: agrega latencia a TODA consulta, sin distinguir cual.
  if (fallas.activa("db_lenta")) {
    await fallas.esperar(fallas.entre(300, 900));
  }
  const resultado = await obtenerPool().query(sql, params);
  return resultado.rows;
}

// Crea las tablas si no existen. Se ejecuta al arrancar cada servicio que usa
// la base; es idempotente, asi que no importa que varios lo intenten a la vez.
async function inicializar() {
  const sentencias = [
    `CREATE TABLE IF NOT EXISTS clientes (
       id SERIAL PRIMARY KEY,
       nombre TEXT NOT NULL,
       email TEXT,
       telefono TEXT,
       origen TEXT,
       creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS vehiculos (
       id SERIAL PRIMARY KEY,
       marca TEXT NOT NULL,
       modelo TEXT NOT NULL,
       anio INT NOT NULL,
       condicion TEXT NOT NULL,
       precio_clp BIGINT NOT NULL,
       sucursal TEXT NOT NULL,
       disponible BOOLEAN NOT NULL DEFAULT true
     )`,
    `CREATE TABLE IF NOT EXISTS agendamientos (
       id SERIAL PRIMARY KEY,
       cliente_nombre TEXT NOT NULL,
       vehiculo_id INT,
       sucursal TEXT NOT NULL,
       fecha_visita DATE NOT NULL,
       estado TEXT NOT NULL DEFAULT 'confirmado',
       creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS oportunidades (
       id SERIAL PRIMARY KEY,
       cliente_id INT,
       vehiculo_id INT,
       etapa TEXT NOT NULL DEFAULT 'contacto',
       monto_clp BIGINT,
       creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS pagos (
       id SERIAL PRIMARY KEY,
       oportunidad_id INT,
       monto_clp BIGINT NOT NULL,
       estado TEXT NOT NULL,
       autorizacion TEXT,
       creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
     )`,
  ];

  for (const sql of sentencias) {
    await obtenerPool().query(sql);
  }

  // Catalogo inicial de vehiculos, solo si la tabla esta vacia.
  const [{ total }] = (
    await obtenerPool().query("SELECT COUNT(*)::int AS total FROM vehiculos")
  ).rows;

  if (total === 0) {
    const marcas = [
      ["Toyota", "Corolla", "nuevo", 18990000],
      ["Toyota", "RAV4", "nuevo", 27990000],
      ["Chevrolet", "Sail", "usado", 8490000],
      ["Hyundai", "Tucson", "nuevo", 24990000],
      ["Hyundai", "Accent", "usado", 9990000],
      ["Nissan", "Versa", "nuevo", 14990000],
      ["Kia", "Sportage", "nuevo", 25990000],
      ["Mazda", "CX-5", "usado", 19990000],
      ["Suzuki", "Swift", "nuevo", 13490000],
      ["Ford", "Ranger", "usado", 22990000],
    ];
    const sucursales = ["Santiago Centro", "Providencia", "Maipu", "Concepcion", "Vina del Mar"];

    for (let i = 0; i < 60; i++) {
      const [marca, modelo, condicion, precio] = marcas[i % marcas.length];
      const sucursal = sucursales[i % sucursales.length];
      const anio = condicion === "nuevo" ? 2026 : 2018 + (i % 7);
      await obtenerPool().query(
        `INSERT INTO vehiculos (marca, modelo, anio, condicion, precio_clp, sucursal, disponible)
         VALUES ($1, $2, $3, $4, $5, $6, true)`,
        [marca, modelo, anio, condicion, precio, sucursal]
      );
    }
    logger.info("catalogo de vehiculos inicializado", { vehiculos: 60 });
  }
}

module.exports = { consultar, inicializar, obtenerPool };
