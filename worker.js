#!/usr/bin/env bash
set -euo pipefail

# Instala uDocker y ejecuta ghcr.io/webtor-io/self-hosted sin Docker daemon.
# Uso:
#   WORKER_BASE_URL=https://file.streamgramm.workers.dev ./scripts/install_udocker_webtor.sh
#
# Nota: uDocker normalmente usa red del host. Webtor escuchará en el puerto 8080.
# Por eso se recomienda que el bot Go use PORT=8099 o cualquier puerto distinto.

UDOCKER_VERSION="${UDOCKER_VERSION:-1.3.17}"
UDOCKER_URL="${UDOCKER_URL:-https://github.com/indigo-dc/udocker/releases/download/${UDOCKER_VERSION}/udocker-${UDOCKER_VERSION}.tar.gz}"
WEBTOR_IMAGE="${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}"
WEBTOR_CONTAINER_NAME="${WEBTOR_CONTAINER_NAME:-webtor_selfhosted}"
BASE_DIR="${WEBTOR_UDOCKER_DIR:-$HOME/qooq-webtor-udocker}"
DOMAIN="${WEBTOR_DOMAIN:-${WORKER_BASE_URL:-http://localhost:8080}}"

mkdir -p "$BASE_DIR" "$BASE_DIR/data" "$BASE_DIR/pgdata" "$BASE_DIR/logs"
cd "$BASE_DIR"

if [ ! -d "udocker-${UDOCKER_VERSION}" ]; then
  echo "⬇️ Descargando uDocker ${UDOCKER_VERSION}..."
  if command -v wget >/dev/null 2>&1; then
    wget -O "udocker-${UDOCKER_VERSION}.tar.gz" "$UDOCKER_URL"
  else
    curl -L -o "udocker-${UDOCKER_VERSION}.tar.gz" "$UDOCKER_URL"
  fi
  tar zxvf "udocker-${UDOCKER_VERSION}.tar.gz"
fi

export PATH="$BASE_DIR/udocker-${UDOCKER_VERSION}/udocker:$PATH"

if ! command -v udocker >/dev/null 2>&1; then
  echo "❌ udocker no quedó en PATH"
  exit 1
fi

echo "🔧 Instalando uDocker..."
udocker install

echo "📦 Pull de Webtor: $WEBTOR_IMAGE"
udocker pull "$WEBTOR_IMAGE"

echo "🧱 Creando contenedor $WEBTOR_CONTAINER_NAME si no existe"
if udocker create --name="$WEBTOR_CONTAINER_NAME" "$WEBTOR_IMAGE" >/tmp/qooq_udocker_create.log 2>&1; then
  echo "✅ Contenedor creado."
else
  echo "ℹ️ No se pudo crear; probablemente ya existe. Se reutilizará."
  cat /tmp/qooq_udocker_create.log || true
fi

cat > "$BASE_DIR/run-webtor.sh" <<RUNEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$BASE_DIR/udocker-${UDOCKER_VERSION}/udocker:\$PATH"
exec udocker run \
  --user=root \
  -v "$BASE_DIR/data:/data" \
  -v "$BASE_DIR/pgdata:/pgdata" \
  -e DOMAIN="$DOMAIN" \
  -e WAIT_FOR_VPN="${WAIT_FOR_VPN:-false}" \
  -e DISABLE_WEBDAV="${DISABLE_WEBDAV:-true}" \
  -e DISABLE_EMBED="${DISABLE_EMBED:-false}" \
  "$WEBTOR_CONTAINER_NAME"
RUNEOF
chmod +x "$BASE_DIR/run-webtor.sh"

if [ -f "$BASE_DIR/webtor.pid" ] && kill -0 "$(cat "$BASE_DIR/webtor.pid")" 2>/dev/null; then
  echo "✅ Webtor ya está corriendo con PID $(cat "$BASE_DIR/webtor.pid")"
else
  echo "🚀 Iniciando Webtor en background..."
  nohup "$BASE_DIR/run-webtor.sh" > "$BASE_DIR/logs/webtor.log" 2>&1 &
  echo $! > "$BASE_DIR/webtor.pid"
  echo "✅ PID: $(cat "$BASE_DIR/webtor.pid")"
fi

cat <<INFO

✅ Webtor self-hosted con uDocker preparado.

Logs:
  tail -f "$BASE_DIR/logs/webtor.log"

Health local:
  curl -i http://127.0.0.1:8080/rest-api/resource/08ada5a7a6183aae1e09d831df6748d566095a10

Config recomendada para el bot:
  PORT=8099
  WEBTOR_ENABLED=true
  WEBTOR_API_BASE_URL=http://127.0.0.1:8080/rest-api
  WEBTOR_TIMEOUT=4m

IMPORTANTE:
  Webtor debe iniciarse con DOMAIN igual a tu Worker si quieres que sus HLS salgan públicos:
  DOMAIN=$DOMAIN

INFO
