# ServerB - imagen que se construye LOCALMENTE (no se sube a un registry).
#
# Construir la imagen:
#   cd ServerB
#   docker build -t serverb-api:local .
#
# Ejecutar el contenedor (expone el puerto 8080):
#   docker run -d --name serverB -p 8080:8080 serverb-api:local
#
# Probar:
#   curl http://localhost:8080/health
#   curl http://localhost:8080/metrics

FROM node:20-alpine

WORKDIR /app

# Se copian primero los manifiestos para aprovechar la cache de capas de Docker:
# si el codigo cambia pero no las dependencias, "npm install" no se vuelve a ejecutar.
COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

ENV PORT=8080
EXPOSE 8080

# HEALTHCHECK: Docker marca el contenedor como "unhealthy" si /health deja de responder.
# Util para que un orquestador (docker compose, ECS, k8s) reinicie el contenedor solo.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:8080/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "src/server.js"]
