# Telegram
BOT_TOKEN=123456789:AA...

# Usuarios administradores separados por coma. Si lo dejas vacío, el primer /start será admin.
ADMIN_IDS=8030036884

# Base pública que ve el usuario. Puede ser tu Cloudflare Worker.
# El Worker debe reenviar /w/{token} a este servidor Go, o puedes publicar este Go directamente.
WORKER_BASE_URL=https://file.streamgramm.workers.dev

# Servidor HTTP local del bot para validar tokens /w/{token}
PORT=8099
DB_PATH=./qooq-cinema.db

# Secreto HMAC para firmar enlaces. Usa 32+ bytes aleatorios.
HASH_SECRET=cambia-esto-por-un-secreto-largo-y-privado

# Tiempo de vida de enlaces: 24h, 7d, 30m, etc.
LINK_TTL=24h

# landing = muestra página bonita con botón/playback; redirect = redirige directo al source_url.
LINK_MODE=landing

# Máximo de episodios enviados en una sola petición de serie. Si hay más, se muestran temporadas.
MAX_SERIES_LINKS=80

# Webtor self-hosted por uDocker para fuentes magnet/torrent legales.
# Webtor escucha normalmente en 127.0.0.1:8080/rest-api dentro del host.
WEBTOR_ENABLED=true
WEBTOR_API_BASE_URL=http://127.0.0.1:8080/rest-api
WEBTOR_TIMEOUT=4m

# Si Webtor fue iniciado con DOMAIN=$WORKER_BASE_URL, deja esto vacío.
# Si Webtor devuelve http://localhost:8080/torrent-http-proxy/..., pon aquí tu Worker:
# WEBTOR_REWRITE_EXPORT_BASE=https://file.streamgramm.workers.dev
WEBTOR_REWRITE_EXPORT_BASE=

# Opcional si proteges Webtor/rest-api con api-key/token.
WEBTOR_API_KEY=
WEBTOR_API_TOKEN=

# Búsqueda externa legal/libre. No incluye scrapers de índices asociados a piratería.
SEARCH_ENABLED=true
SEARCH_MAX_RESULTS=6
# RSS/Atom legal configurable. Usa {query} si el feed soporta búsqueda.
TORRENT_RSS_URLS=
# Allowlist para URLs .torrent de esos RSS. Déjalo vacío para aceptar sólo mismo host del feed.
ALLOWED_TORRENT_HOSTS=

LOG_LEVEL=INFO
DEFAULT_LANG=es
