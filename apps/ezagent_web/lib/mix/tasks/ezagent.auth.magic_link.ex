defmodule Mix.Tasks.Ezagent.Auth.MagicLink do
  @shortdoc "Operator debug — request a magic-link for <email>, print the result"
  @moduledoc """
  Operator/debug CLI for the magic-link flow. Mirrors the exact same
  decision logic as `EzagentWeb.SessionController.maybe_send_magic_link/2`
  BUT does NOT honor anti-enumeration: stdout prints exactly what
  happened (sent / dropped + reason). This is an operator tool — the
  user-facing HTTP response stays anti-enumeration-uniform.

  ## Usage

      MIX_ENV=prod mix ezagent.auth.magic_link lin.yilun@h2oslabs.com

  ## Why this exists

  Allen 2026-05-23: "我刚又尝试使用 magic link 登录 ...依然无法收到邮件
  ...登录等 auth 功能有 cli 吗?". The `/login` LV form has 4 silent-drop
  paths (SMTP unconfigured / email-rate-limited / IP-rate-limited /
  domain not in whitelist / mailer error). Logger.warning was added
  (PR #266) but logs are only visible if the operator has shell on
  the prod box AND has restarted the server since the log PR landed.

  This CLI is the immediate-answer alternative: run it on prod, get
  the answer in stdout in 1 second. No log-grepping, no restart-
  ordering risk.

  ## Exit codes

  - 0: email was sent (Mailer.deliver_magic_link returned {:ok, _})
  - 1: silent-drop (SMTP / rate-limit / whitelist / mailer error)
       — stdout prints which one

  ## Limitations

  - Does NOT bypass cap checks (there aren't any on this path; it's
    the public anti-enumeration login surface).
  - Does NOT bypass rate-limiting — running this CLI counts against
    the email's 3/15min limit. So if you've been retrying via LV
    and just got rate-limited, the CLI will also see :email_rate_limited
    and tell you so. (Operator workflow: wait 15 min OR clear the
    rate-limit ETS table.)
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case args do
      [email] ->
        do_run(email)

      _ ->
        Mix.shell().error("Usage: mix ezagent.auth.magic_link <email>")
        Mix.raise("missing email arg")
    end
  end

  defp do_run(raw_email) do
    email = raw_email |> String.trim() |> String.downcase()

    Mix.shell().info("Requesting magic-link for: #{email}")
    Mix.shell().info("")

    cond do
      not Ezagent.AppSettings.smtp_configured?() ->
        Mix.shell().error("DROP reason=smtp_not_configured")
        Mix.shell().info("→ Admin must configure SMTP at /admin/settings → SMTP first.")
        Mix.shell().info("→ Inspect current config with:")
        Mix.shell().info("    Ezagent.AppSettings.get(\"smtp_config\")")
        System.halt(1)

      {:error, :rate_limited} ==
          EzagentWeb.RateLimiter.check("login_email:" <> email,
            limit: 3,
            window_ms: 15 * 60_000
          ) ->
        Mix.shell().error("DROP reason=email_rate_limited (3/15min hit)")
        Mix.shell().info("→ Wait 15 min, or clear the ETS table:")
        Mix.shell().info("    :ets.delete(:ezagent_rate_limiter, \"login_email:#{email}\")")
        System.halt(1)

      not send_allowed?(email) ->
        Mix.shell().error("DROP reason=send_not_allowed")
        Mix.shell().info("→ This email is neither an existing principal nor in the")
        Mix.shell().info("  `registration_domains` whitelist.")
        Mix.shell().info("→ Inspect current whitelist:")
        Mix.shell().info("    Ezagent.AppSettings.get(\"registration_domains\")")
        Mix.shell().info("→ Add the domain via /admin/settings → Allowed email domains")
        Mix.shell().info("  OR programmatically:")

        Mix.shell().info(
          "    Ezagent.AppSettings.put(\"registration_domains\", [\"#{domain_of(email)}\"])"
        )

        System.halt(1)

      true ->
        do_send(email)
    end
  end

  defp do_send(email) do
    {:ok, raw} = Ezagent.Entity.MagicLinkToken.mint(email)
    link = EzagentWeb.Endpoint.url() <> "/auth/magic/" <> raw

    case EzagentWeb.Mailer.deliver_magic_link(email, link) do
      {:ok, _} ->
        Mix.shell().info("✓ SENT — Mailer returned :ok")
        Mix.shell().info("  Link valid for 15 min (token id: #{String.slice(raw, 0, 8)}…)")

      {:error, reason} ->
        Mix.shell().error("DROP reason=mailer_failed mailer_reason=#{inspect(reason)}")
        Mix.shell().info("→ Common causes: TLS handshake failure, network unreachable,")
        Mix.shell().info("  SMTP creds wrong, port blocked by upstream.")
        Mix.shell().info("→ Check SMTP config:")
        Mix.shell().info("    Ezagent.AppSettings.get(\"smtp_config\")")
        System.halt(1)
    end
  end

  defp send_allowed?(email) do
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, _uri} -> true
      :none -> Ezagent.Registration.domain_allowed?(email)
    end
  end

  defp domain_of(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> domain
      _ -> "<unknown>"
    end
  end
end
