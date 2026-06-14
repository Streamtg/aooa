// Cloudflare Worker para Qooq Cinema + Webtor self-hosted.
//
// Rutas:
//   /w/{token}                 -> servidor Go del bot
//   /torrent-http-proxy/{...}  -> Webtor self-hosted (HLS, segmentos, DDL)
//   /rest-api/{...}            -> bloqueado por defecto para no exponer API de Webtor
//
// Variables requeridas en Cloudflare:
//   BOT_ORIGIN_BASE_URL    = "https://tu-servidor-go.example.com"
//   WEBTOR_ORIGIN_BASE_URL = "https://tu-webtor-origin.example.com"
//
// Si Go y Webtor están detrás del mismo reverse proxy/origen, ambas variables pueden apuntar
// al mismo dominio público y tu proxy local decide por path.

export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);

    if (incoming.pathname.startsWith("/w/") || incoming.pathname === "/healthz") {
      return proxyTo(request, incoming, env.BOT_ORIGIN_BASE_URL, false);
    }

    if (incoming.pathname.startsWith("/torrent-http-proxy/")) {
      return proxyTo(request, incoming, env.WEBTOR_ORIGIN_BASE_URL, true);
    }

    if (incoming.pathname.startsWith("/rest-api/")) {
      return new Response("Webtor REST API is private", { status: 403 });
    }

    return new Response("Qooq Cinema Worker OK", {
      status: 200,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};

async function proxyTo(request, incomingURL, originBase, allowRange) {
  if (!originBase) {
    return new Response("Origin is not configured", { status: 500 });
  }

  const target = new URL(originBase);
  target.pathname = incomingURL.pathname;
  target.search = incomingURL.search;

  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-Host", incomingURL.host);
  headers.set("X-Forwarded-Proto", incomingURL.protocol.replace(":", ""));

  if (!allowRange) {
    headers.delete("range");
  }

  const resp = await fetch(target.toString(), {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    redirect: "manual",
  });

  const outHeaders = new Headers(resp.headers);
  outHeaders.set("Access-Control-Allow-Origin", "*");
  outHeaders.set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  outHeaders.set("Access-Control-Allow-Headers", "Range, Content-Type, Authorization");

  return new Response(resp.body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: outHeaders,
  });
}
