// Minimal Cloudflare Worker for the #65 toy demo.
// Goal: validate that we can authenticate, deploy a Worker, and wire a custom
// subdomain without touching the existing app./dev. tunnels.
export default {
  async fetch(request, _env, _ctx) {
    const url = new URL(request.url);
    const body = JSON.stringify(
      {
        ok: true,
        msg: "ezagent CF toy worker: deploy + domain wiring verified",
        host: url.host,
        path: url.pathname,
        ts: new Date().toISOString(),
      },
      null,
      2,
    );

    return new Response(body + "\n", {
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  },
};
