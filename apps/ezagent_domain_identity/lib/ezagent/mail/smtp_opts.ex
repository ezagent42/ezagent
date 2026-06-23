defmodule Ezagent.Mail.SmtpOpts do
  @moduledoc """
  Pure mapping from a stored `smtp_config` map to `Swoosh.Adapters.SMTP`
  options. Shared by `EzagentWeb.Mailer` and `Ezagent.Email.Mailer` (task #88)
  so the OTP 27/28 TLS handling lives in exactly one place.

  Lives in `ezagent_domain_identity` (where `Ezagent.AppSettings` stores
  `smtp_config`; `ezagent_web` already depends on identity, so no cycle). It is a
  pure function and MUST NOT depend on `:swoosh` or any transport — it only
  shapes an options keyword list.

  Port semantics: 465 → implicit SSL (`ssl: true, tls: :never`); 587 (and other
  non-465 ports) → STARTTLS (`ssl: false`, `tls: :always` unless `tls: false`).
  """

  @spec from_config(map()) :: keyword()
  def from_config(cfg) when is_map(cfg) do
    port = to_int(Map.fetch!(cfg, "port"))
    host = Map.fetch!(cfg, "host")

    base = [
      relay: host,
      port: port,
      username: Map.fetch!(cfg, "username"),
      password: Map.fetch!(cfg, "password"),
      auth: :always,
      tls_options: tls_options(host)
    ]

    if port == 465 do
      base ++ [ssl: true, tls: :never]
    else
      tls_mode = if Map.get(cfg, "tls", true), do: :always, else: :never
      base ++ [ssl: false, tls: tls_mode]
    end
  end

  # OTP 27/28-compatible TLS options: system CA bundle, SNI, modern versions.
  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(String.trim(s))
end
