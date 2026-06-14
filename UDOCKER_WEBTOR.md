# Webtor self-hosted con uDocker para Qooq Cinema

> Úsalo únicamente con torrents/magnets que tengas derecho a reproducir o distribuir.

## Corrección importante de tus comandos

Tu línea:

```bash
export PATH`pwd`:$PATH
```

Debe ser:

```bash
export PATH="$(pwd):$PATH"
```

Además, para Webtor no necesitas crear primero un Ubuntu y editar `apt sources`. uDocker puede ejecutar directamente la imagen Docker de Webtor:

```bash
udocker pull ghcr.io/webtor-io/self-hosted:latest
udocker create --name=webtor_selfhosted ghcr.io/webtor-io/self-hosted:latest
udocker run --user=root \
  -v "$HOME/qooq-webtor-udocker/data:/data" \
  -v "$HOME/qooq-webtor-udocker/pgdata:/pgdata" \
  -e DOMAIN="https://file.streamgramm.workers.dev" \
  webtor_selfhosted
```

## Instalación automatizada

Desde la carpeta del bot:

```bash
cd qooq-cinema
chmod +x scripts/install_udocker_webtor.sh
WORKER_BASE_URL=https://file.streamgramm.workers.dev ./scripts/install_udocker_webtor.sh
```

Webtor quedará escuchando normalmente en:

```text
http://127.0.0.1:8080
http://127.0.0.1:8080/rest-api
```

Por eso el bot Go debería usar otro puerto, por ejemplo:

```env
PORT=8099
WEBTOR_ENABLED=true
WEBTOR_API_BASE_URL=http://127.0.0.1:8080/rest-api
WORKER_BASE_URL=https://file.streamgramm.workers.dev
```

## Worker

Cloudflare Worker debe enviar:

```text
/w/{token}                -> origen del bot Go
/torrent-http-proxy/{...} -> origen Webtor
```

Variables del Worker:

```text
BOT_ORIGIN_BASE_URL=https://tu-origen-bot.example.com
WEBTOR_ORIGIN_BASE_URL=https://tu-origen-webtor.example.com
```

## Cómo funciona internamente

Cuando una película/episodio tiene un `source_url` tipo `magnet:?xt=urn:btih:...`:

1. El usuario pide el título al bot.
2. El bot devuelve `https://worker/w/{token}`.
3. El endpoint `/w/{token}` valida firma HMAC y expiración.
4. El bot llama a Webtor:
   - `POST /resource/` con el magnet.
   - `GET /resource/{id}/list` para listar archivos.
   - Selecciona el archivo reproducible más grande.
   - `GET /resource/{id}/export/{content_id}?types=stream,download`.
5. Webtor devuelve un HLS/DDL bajo `/torrent-http-proxy/...`.
6. La landing del bot reproduce el HLS usando el Worker.

## Prueba rápida manual

```bash
curl -sS -X POST \
  --data 'magnet:?xt=urn:btih:INFOHASH_AQUI&dn=Nombre' \
  http://127.0.0.1:8080/rest-api/resource/
```

La respuesta debe incluir:

```json
{"id":"...","name":"...","magnet_uri":"..."}
```
