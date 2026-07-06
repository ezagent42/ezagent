defmodule EzagentWeb.Plugs.CloudflareRemoteIp do
  @moduledoc """
  Rewrite `conn.remote_ip` from Cloudflare's `CF-Connecting-IP` header so the
  app sees the REAL client IP, not the `cloudflared` tunnel's internal address.

  ## Why

  In production the app is reached ONLY through a `cloudflared` tunnel, whose
  container connects to the BEAM over the docker network. So every request's
  socket peer (`conn.remote_ip`) is the tunnel's private address
  (e.g. `::ffff:192.168.107.7`) — identical for every real client. That
  collapses the per-IP throttles in `EzagentWeb.RateLimiter` (the
  `login_ip:<ip>` 10/hour magic-link + password-reset limits) into a single
  GLOBAL bucket: once any handful of users exhaust it, everyone else's
  magic-link / reset requests are silently dropped. `cloudflared` sets
  `CF-Connecting-IP` to the true client IP (determined at Cloudflare's edge),
  so keying rate limits on that restores real per-client throttling.

  ## Trust model

  We rewrite ONLY when the DIRECT socket peer is a private / loopback address —
  i.e. the request genuinely arrived through the local tunnel (or a local proxy
  in dev). If the app port is ever exposed directly to a public client, that
  client's socket peer is public, so its forged `CF-Connecting-IP` is IGNORED
  (no rewrite). This is the trusted-proxy pattern without a CIDR allowlist to
  keep in sync. `CF-Connecting-IP` is a single client IP (Cloudflare guarantees
  one value), so there is no forwarded-chain to parse.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with true <- trusted_peer?(conn.remote_ip),
         [value | _] <- get_req_header(conn, "cf-connecting-ip"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(String.trim(value))) do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  # A private/loopback DIRECT peer means the request came via the local tunnel
  # (or a local dev proxy) — the only place we trust `CF-Connecting-IP`.
  @spec trusted_peer?(:inet.ip_address()) :: boolean()
  defp trusted_peer?({127, _, _, _}), do: true
  defp trusted_peer?({10, _, _, _}), do: true
  defp trusted_peer?({192, 168, _, _}), do: true
  defp trusted_peer?({172, b, _, _}) when b >= 16 and b <= 31, do: true

  # IPv6 loopback ::1 and Unique-Local Address fc00::/7 (first hextet fc00..fdff).
  defp trusted_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp trusted_peer?({h, _, _, _, _, _, _, _}) when h >= 0xFC00 and h <= 0xFDFF, do: true

  # IPv4-mapped IPv6 (::ffff:a.b.c.d — how the tunnel peer appears): unwrap the
  # embedded IPv4 and re-test its private ranges.
  defp trusted_peer?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    trusted_peer?(
      {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}
    )
  end

  defp trusted_peer?(_), do: false
end
