CREATE TABLE IF NOT EXISTS clientes (id SERIAL PRIMARY KEY, nombre TEXT NOT NULL, email TEXT, telefono TEXT, origen TEXT, creado_en TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS vehiculos (id SERIAL PRIMARY KEY, marca TEXT NOT NULL, modelo TEXT NOT NULL, anio INT NOT NULL, condicion TEXT NOT NULL, precio_clp BIGINT NOT NULL, sucursal TEXT NOT NULL, disponible BOOLEAN NOT NULL DEFAULT true);
CREATE TABLE IF NOT EXISTS agendamientos (id SERIAL PRIMARY KEY, cliente_nombre TEXT NOT NULL, vehiculo_id INT, sucursal TEXT NOT NULL, fecha_visita DATE NOT NULL, estado TEXT NOT NULL DEFAULT 'confirmado', creado_en TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS oportunidades (id SERIAL PRIMARY KEY, cliente_id INT, vehiculo_id INT, etapa TEXT NOT NULL DEFAULT 'contacto', monto_clp BIGINT, creado_en TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS pagos (id SERIAL PRIMARY KEY, oportunidad_id INT, monto_clp BIGINT NOT NULL, estado TEXT NOT NULL, autorizacion TEXT, creado_en TIMESTAMPTZ NOT NULL DEFAULT now());

INSERT INTO vehiculos (marca, modelo, anio, condicion, precio_clp, sucursal)
SELECT * FROM (VALUES
 ('Toyota','Corolla',2026,'nuevo',18990000,'Santiago Centro'),
 ('Hyundai','Tucson',2026,'nuevo',24990000,'Providencia'),
 ('Chevrolet','Sail',2020,'usado',8490000,'Maipu'),
 ('Kia','Sportage',2026,'nuevo',25990000,'Concepcion'),
 ('Mazda','CX-5',2019,'usado',19990000,'Vina del Mar'),
 ('Nissan','Versa',2026,'nuevo',14990000,'Santiago Centro'),
 ('Ford','Ranger',2021,'usado',22990000,'Providencia'),
 ('Suzuki','Swift',2026,'nuevo',13490000,'Maipu'),
 ('Toyota','RAV4',2026,'nuevo',27990000,'Concepcion'),
 ('Hyundai','Accent',2018,'usado',9990000,'Vina del Mar')
) AS datos(marca, modelo, anio, condicion, precio_clp, sucursal)
WHERE NOT EXISTS (SELECT 1 FROM vehiculos);
