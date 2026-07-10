defmodule EzagentWeb.UrlHelper do
  @moduledoc """
  Derives the public base URL for links emailed to a user (magic-link,
  email-confirmation, password-reset) from the **request they actually made**,
  not the statically configured `public_host`.

  ## Why this exists

  `EzagentWeb.Endpoint.url/0` returns the single compile/runtime-configured
  `public_host` (`EZAGENT_PUBLIC_HOST`). On the deployment, several hostnames
  (`canary.ezagent.chat`, `nightly.ezagent.chat`) are served by the **same**
  container behind Caddy, whose `EZAGENT_PUBLIC_HOST` is a single value. A user
  who signs in on `canary.ezagent.chat` would therefore receive a
  `nightly.ezagent.chat` link — the wrong host. Building the link from
  `conn.host` fixes that, because Caddy preserves the original `Host` header.

  ## Host-header injection guard

  `conn.host` is attacker-controllable (it is the `Host` request header), so we
  only trust hosts we own — `localhost`, `ezagent.chat`, and any
  `*.ezagent.chat`. An attacker sending `Host: evil.com` fails the allowlist and
  we fall back to the configured `Endpoint.url/0`, so a poisoned link is never
  emailed.
  """

  @doc """
  Return the base URL (`scheme://authority`, no trailing slash) for links sent
  to `conn`'s user.

  When `conn.host` is a trusted host (see the module doc allowlist) the returned
  URL uses that request host with the deployment's configured public scheme/port
  (`:ezagent_domain_session` `:public_scheme` / `:public_port`). Behind Caddy the
  app terminates plain HTTP internally while the public scheme is HTTPS, so we
  take scheme/port from config and only the **host** from the request — this
  avoids emitting `http://` links.

  For any untrusted host it falls back to `EzagentWeb.Endpoint.url/0` (current
  behavior), which is the host-header injection guard.
  """
  @spec request_base_url(Plug.Conn.t()) :: String.t()
  def request_base_url(%Plug.Conn{host: host}) when is_binary(host) do
    if trusted_host?(host) do
      scheme = Application.get_env(:ezagent_domain_session, :public_scheme, "https")
      port = Application.get_env(:ezagent_domain_session, :public_port, 443)
      "#{scheme}://#{authority(host, scheme, port)}"
    else
      EzagentWeb.Endpoint.url()
    end
  end

  # We own ezagent.chat; localhost covers dev. Everything else is untrusted.
  defp trusted_host?("localhost"), do: true
  defp trusted_host?("ezagent.chat"), do: true
  defp trusted_host?(host), do: String.ends_with?(host, ".ezagent.chat")

  # Omit the port for the default scheme/port pairs; include it otherwise.
  defp authority(host, "https", 443), do: host
  defp authority(host, "http", 80), do: host
  defp authority(host, _scheme, port), do: "#{host}:#{port}"
end
