# Imagen unica para las seis plataformas de Andys Motors.
#
# El servicio concreto se elige con la variable de entorno SERVICIO:
#   web | stock | agenda | crm | pagos | gateway
#
# Se construye una sola vez y se ejecuta con distinta configuracion en cada
# servidor. Es el mismo patron de ServerB en EA2/Act2-1, extendido a varios
# servicios.
#
#   docker build -t andys-motors:local .
#   docker run -d -e SERVICIO=stock -p 8080:8080 andys-motors:local

FROM node:20-alpine

WORKDIR /app

# Primero los manifiestos, para aprovechar la cache de capas de Docker.
COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:'+(process.env.PORT||8080)+'/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "src/index.js"]
