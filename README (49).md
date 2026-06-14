#!/command/with-contenv sh
set -a
source /etc/webtor/common.env
source /etc/webtor/secrets/api.env
WEB_PORT=$TORRENT_HTTP_PROXY_SERVICE_PORT
CONFIG_PATH=/etc/webtor/torrent-http-proxy/config.yaml
set +a
/app/torrent-http-proxy 2>&1 | s6-log p"[torrent-http-proxy]" 1