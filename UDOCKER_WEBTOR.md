# Qooq Cinema Bot

Bot de Telegram en Go para catálogo de películas y series. Detecta idioma, busca en SQLite,
genera enlaces seguros tipo Worker y devuelve películas o secuencias de episodios organizadas por temporada.

## Ejecutar

```bash
cp .env.example .env
# edita .env
set -a && source .env && set +a
go mod tidy
go run .
```

## Admin rápido

```text
/addmovie Dune: Part Two | 2024 | 1080p | https://tu-stream/Dune2.mp4 | Paul Atreides une fuerzas con Chani.
/addmovie Sintel | 2010 | 1080p | magnet:?xt=urn:btih:INFOHASH_AQUI&dn=Sintel | Película abierta vía Webtor self-hosted.
/addserie The Boys | 2019 | Superhéroes corruptos y vigilancia corporativa.
/addepisode The Boys | 1 | 1 | The Name of the Game | 1080p | https://tu-stream/theboys/s01e01.mp4
/addepisode Serie Legal | 1 | 1 | Piloto | 1080p | magnet:?xt=urn:btih:INFOHASH_EPISODIO
/bulkepisodes The Boys | 1
2 | Cherry | 1080p | https://tu-stream/theboys/s01e02.mp4
3 | Get Some | 1080p | https://tu-stream/theboys/s01e03.mp4
```

Luego el usuario escribe: `The Boys` y el bot responde con los enlaces por temporada/capítulo.

## Webtor self-hosted con uDocker

Guía extendida: [`UDOCKER_WEBTOR.md`](UDOCKER_WEBTOR.md).

Este bot acepta `source_url` HTTP/HTTPS, `.torrent` HTTP/HTTPS y también `magnet:?xt=urn:btih:...` cuando `WEBTOR_ENABLED=true`.

También incluye `/search <título>` para proveedores legales/libres integrados: WebTorrent demo torrents, Internet Archive y RSS/Atom configurables por allowlist. No incluye scrapers de 1337x, KAT, BTDig, Nyaa o BitSearch.

Flujo torrent legal:

```text
Usuario pide título
  -> bot genera https://worker/w/{token}
  -> /w/{token} valida HMAC/TTL
  -> Go llama a Webtor REST API: POST /resource, GET /list, GET /export
  -> Webtor devuelve HLS/DDL bajo /torrent-http-proxy
  -> Worker proxyficará /torrent-http-proxy hacia Webtor
```

Instalación rápida:

```bash
chmod +x scripts/install_udocker_webtor.sh
WORKER_BASE_URL=https://file.streamgramm.workers.dev ./scripts/install_udocker_webtor.sh
```

Variables relevantes del bot:

```env
WEBTOR_ENABLED=true
WEBTOR_API_BASE_URL=http://127.0.0.1:8080/rest-api
WEBTOR_TIMEOUT=4m
WEBTOR_REWRITE_EXPORT_BASE=
```

Si Webtor devuelve enlaces con `localhost`, define:

```env
WEBTOR_REWRITE_EXPORT_BASE=https://file.streamgramm.workers.dev
```

## Worker

El archivo `worker.js` es opcional. Si quieres que los enlaces públicos salgan con tu dominio Worker:

1. Despliega `worker.js` en Cloudflare Workers.
2. Configura variables:

```text
BOT_ORIGIN_BASE_URL=https://tu-servidor-go.example.com
WEBTOR_ORIGIN_BASE_URL=https://tu-webtor-origin.example.com
```

3. En el bot usa:

```env
WORKER_BASE_URL=https://tu-worker.workers.dev
```

El Worker reenvía `/w/{token}` al servidor Go y `/torrent-http-proxy/...` a Webtor. La REST API de Webtor queda bloqueada por defecto.
