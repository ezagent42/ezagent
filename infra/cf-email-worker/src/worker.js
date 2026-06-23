import PostalMime from "postal-mime";

// task #88 — inbound email for ezagent.chat. Email Routing catch-all → this
// Worker's email() handler parses each message and caches it in KV. The fetch()
// handler exposes a token-authed pull API so ezagent (or an operator) can list
// and fetch received mail.
const TTL = 60 * 60 * 24 * 30; // 30 days

export default {
  async email(message, env, ctx) {
    try {
      const parsed = await new PostalMime().parse(message.raw);
      const ts = Date.now();
      const to = (message.to || "unknown").toLowerCase();
      const mid = (parsed.messageId || "").replace(/[^A-Za-z0-9._-]/g, "").slice(0, 60);
      const key = `inbox:${to}:${ts}:${mid}`;

      // task #88 PR-2 §4.5a — capture the headers ezagent needs to enforce
      // inbound auth (SPF/DKIM/DMARC) AND the loop/bounce guard, in ONE
      // revision. Cloudflare Email Routing computes the auth verdict on the
      // `Authentication-Results` header; `Auto-Submitted` / `Precedence`
      // mark auto-replies + bulk mail; an empty envelope-from (`<>`) is the
      // RFC 5321 bounce marker.
      const header = (name) => {
        const h = parsed.headers && parsed.headers.find
          ? parsed.headers.find((x) => (x.key || "").toLowerCase() === name)
          : null;
        return h ? h.value : "";
      };

      // #88 PR-2 BLOCKER 2 — the auth-relevant sender is the HEADER From
      // (`parsed.from`, what DMARC aligns + what the human "sends from"), NOT
      // the envelope sender (`message.from` = RFC 5321 MAIL FROM, used only for
      // the bounce check). Capture the header From's address for ezagent's
      // From-match gate.
      const headerFromAddr =
        (parsed.from && (parsed.from.address || parsed.from.name)) || header("from") || "";

      const record = {
        key,
        // `from` = HEADER From address (auth/From-match identity).
        from: headerFromAddr,
        to,
        subject: parsed.subject || "",
        date: parsed.date || null,
        text: parsed.text || "",
        html: parsed.html || "",
        messageId: parsed.messageId || "",
        receivedAt: new Date(ts).toISOString(),
        size: message.rawSize || 0,
        // #88 PR-2 §4.5a auth + loop-guard fields:
        authResults: header("authentication-results"),
        autoSubmitted: header("auto-submitted"),
        precedence: header("precedence"),
        // envelope-from (RFC 5321 MAIL FROM); empty `<>` = bounce/NDR.
        returnPath: message.from || "",
      };

      await env.EMAIL_INBOX.put(key, JSON.stringify(record), { expirationTtl: TTL });
    } catch (err) {
      console.error("email cache failed:", err && err.stack ? err.stack : err);
      // Don't reject — we don't want the sender to retry forever on a parse bug.
    }
  },

  async fetch(request, env) {
    const expected = env.PULL_TOKEN;
    const auth = request.headers.get("authorization") || "";
    if (!expected || auth !== `Bearer ${expected}`) {
      return new Response("unauthorized\n", { status: 401 });
    }

    const url = new URL(request.url);

    if (url.pathname === "/inbox") {
      const toParam = url.searchParams.get("to");
      const prefix = toParam ? `inbox:${toParam.toLowerCase()}:` : "inbox:";
      const list = await env.EMAIL_INBOX.list({ prefix, limit: 100 });
      const emails = [];
      for (const k of list.keys) {
        const v = await env.EMAIL_INBOX.get(k.name);
        if (v) emails.push(JSON.parse(v));
      }
      emails.sort((a, b) => (b.receivedAt > a.receivedAt ? 1 : -1));
      return Response.json({ count: emails.length, emails });
    }

    if (url.pathname.startsWith("/inbox/")) {
      const key = decodeURIComponent(url.pathname.slice("/inbox/".length));
      const v = await env.EMAIL_INBOX.get(key);
      if (!v) return new Response("not found\n", { status: 404 });
      return new Response(v, { headers: { "content-type": "application/json" } });
    }

    return new Response(
      "ezagent inbound email cache.\n  GET /inbox[?to=<addr>] — list\n  GET /inbox/<key> — one message\n(Authorization: Bearer <token>)\n",
      { headers: { "content-type": "text/plain" } }
    );
  },
};
