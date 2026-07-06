defmodule EzagentWeb.Mailer do
  @moduledoc """
  Username & Auth M2 — outbound email.

  SMTP relay + credentials are NOT in compile-time config — they live
  in `Ezagent.AppSettings` (`"smtp_config"`), set by the admin in the
  Phase 8 settings UI at runtime. `deliver_magic_link/2` reads that
  config and passes it to `Swoosh.Mailer.deliver/2` as a per-delivery
  override.
  """
  use Swoosh.Mailer, otp_app: :ezagent_web

  import Swoosh.Email

  @doc """
  Build (do not send) the magic-link email. Pure — unit-testable.

  Opts: `:url` (the magic link), `:from_address`.
  """
  @spec build_magic_link_email(String.t(), keyword()) :: Swoosh.Email.t()
  def build_magic_link_email(to_email, opts) do
    url = Keyword.fetch!(opts, :url)
    from_address = Keyword.fetch!(opts, :from_address)

    new()
    |> to(to_email)
    |> from({"Ezagent", from_address})
    |> subject("Your Ezagent sign-in link")
    |> text_body("""
    Sign in to Ezagent by opening this link (valid for 15 minutes):

    #{url}

    If you did not request this, you can ignore this email.
    """)
    |> html_body("""
    <p>Sign in to Ezagent by opening this link (valid for 15 minutes):</p>
    <p><a href="#{url}">#{url}</a></p>
    <p style="color:#888;font-size:12px;">If you did not request this, ignore this email.</p>
    """)
  end

  @doc """
  Build (do not send) the email-confirmation email (task #87 self-registration).
  Opts: `:url` (the confirm link), `:from_address`.
  """
  @spec build_confirmation_email(String.t(), keyword()) :: Swoosh.Email.t()
  def build_confirmation_email(to_email, opts) do
    url = Keyword.fetch!(opts, :url)
    from_address = Keyword.fetch!(opts, :from_address)

    new()
    |> to(to_email)
    |> from({"Ezagent", from_address})
    |> subject("Confirm your Ezagent email")
    |> text_body("""
    Confirm your email to finish creating your Ezagent account (valid for 15 minutes):

    #{url}

    If you did not sign up, you can ignore this email.
    """)
    |> html_body("""
    <p>Confirm your email to finish creating your Ezagent account (valid for 15 minutes):</p>
    <p><a href="#{url}">#{url}</a></p>
    <p style="color:#888;font-size:12px;">If you did not sign up, ignore this email.</p>
    """)
  end

  @doc """
  Build (do not send) the password-reset email (task #87).
  Opts: `:url` (the reset link), `:from_address`.
  """
  @spec build_password_reset_email(String.t(), keyword()) :: Swoosh.Email.t()
  def build_password_reset_email(to_email, opts) do
    url = Keyword.fetch!(opts, :url)
    from_address = Keyword.fetch!(opts, :from_address)

    new()
    |> to(to_email)
    |> from({"Ezagent", from_address})
    |> subject("Reset your Ezagent password")
    |> text_body("""
    Reset your Ezagent password by opening this link (valid for 15 minutes):

    #{url}

    If you did not request this, you can ignore this email.
    """)
    |> html_body("""
    <p>Reset your Ezagent password by opening this link (valid for 15 minutes):</p>
    <p><a href="#{url}">#{url}</a></p>
    <p style="color:#888;font-size:12px;">If you did not request this, ignore this email.</p>
    """)
  end

  @doc """
  Build + deliver the magic-link email using the runtime SMTP config.

  Returns `{:error, :mail_not_configured}` if mail can't be sent yet — callers
  MUST treat this as "do not proceed".
  """
  @spec deliver_magic_link(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_magic_link(to_email, url) do
    deliver_link(to_email, url, &build_magic_link_email/2)
  end

  @doc "Build + deliver the email-confirmation email (task #87)."
  @spec deliver_confirmation(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_confirmation(to_email, url) do
    deliver_link(to_email, url, &build_confirmation_email/2)
  end

  @doc "Build + deliver the password-reset email (task #87)."
  @spec deliver_password_reset(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_password_reset(to_email, url) do
    deliver_link(to_email, url, &build_password_reset_email/2)
  end

  # Shared deliver path for all link emails (magic / confirm / reset).
  #
  # task #87 (Codex plan-review #8): the Swoosh adapter is fixed at compile
  # time. In dev/test it is `Swoosh.Adapters.Local` (in-memory) and is
  # unconditionally ready — `smtp_config` is irrelevant there. In prod it is
  # `Swoosh.Adapters.SMTP` and needs the admin's runtime `smtp_config`.
  defp deliver_link(to_email, url, build_fun) do
    if mail_ready?() do
      from_address = from_address()
      email = build_fun.(to_email, url: url, from_address: from_address)
      deliver_built(email)
    else
      {:error, :mail_not_configured}
    end
  end

  # Readiness by adapter:
  #   - Local (dev/test): always ready — never touches the DB.
  #   - EzagentChatAdapter (prod, REST): needs base_url + api_key in smtp_config.
  #   - SMTP: needs the full host/port/... smtp_config.
  defp mail_ready? do
    case configured_adapter() do
      Swoosh.Adapters.Local -> true
      Ezagent.Mail.EzagentChatAdapter -> Ezagent.AppSettings.mail_api_configured?()
      _ -> Ezagent.AppSettings.smtp_configured?()
    end
  end

  defp deliver_built(email) do
    case configured_adapter() do
      Swoosh.Adapters.Local ->
        deliver(email)

      Ezagent.Mail.EzagentChatAdapter ->
        cfg = Ezagent.AppSettings.get("smtp_config") || %{}
        deliver(email, base_url: cfg["base_url"], api_key: cfg["api_key"])

      _ ->
        deliver(email, smtp_runtime_config(Ezagent.AppSettings.get("smtp_config")))
    end
  end

  # From address. Under the Local adapter (dev/test) we never touch the DB —
  # use the default. Under SMTP, use the admin-configured from_address.
  defp from_address do
    case configured_adapter() do
      Swoosh.Adapters.Local ->
        "no-reply@ezagent.chat"

      _ ->
        case Ezagent.AppSettings.get("smtp_config") do
          %{"from_address" => addr} when is_binary(addr) and addr != "" -> addr
          _ -> "no-reply@ezagent.chat"
        end
    end
  end

  defp configured_adapter do
    Application.get_env(:ezagent_web, __MODULE__, [])[:adapter]
  end

  # Map the stored smtp_config map into Swoosh.Adapters.SMTP options.
  #
  # TLS configuration (Allen Feishu 2026-05-21): Erlang OTP 27/28 enforces
  # stricter TLS defaults than OTP 26. Without explicit `:tls_options`,
  # the SMTP TLS handshake fails with `:tls_failed` against many real
  # providers (Feishu Lark, Gmail, etc.) because:
  #   - Default cipher list excludes some server-required suites
  #   - Default `verify: :verify_peer` requires the system CA bundle
  #     to be loaded explicitly via `:public_key.cacerts_get/0`
  #   - Default versions list may not include the server's preferred TLS
  #
  # The block below is the Phoenix 1.8 + OTP 27/28 standard for SMTP+TLS.
  # Port semantics:
  #   - 465 → implicit SSL (set `ssl: true`, `tls: :never`)
  #   - 587 → STARTTLS (set `ssl: false`, `tls: :always`) — most common
  #   - 25  → plaintext (set `ssl: false`, `tls: :never`)
  # SMTP option mapping (465 implicit-SSL vs 587 STARTTLS + OTP 27/28 TLS) lives
  # in the shared pure helper so it isn't duplicated with Ezagent.Email.Mailer
  # (task #88).
  defp smtp_runtime_config(cfg), do: Ezagent.Mail.SmtpOpts.from_config(cfg)
end
