defmodule Mix.Tasks.Ezagent.Auth.MagicLink do
  @shortdoc "Operator debug — request a magic-link for <email>, print the result"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (CLI-only by design).**
  > Intentionally NOT a dispatched op. Operator-debug mirror of the
  > public `/login` HTTP path that intentionally DROPS anti-enumeration
  > so the operator can diagnose silent-drop reasons (SMTP / rate /
  > whitelist). The HTTP surface stays anti-enumeration-uniform; this
  > CLI is the diagnostic counterpart. Stays as `mix ezagent.*`; do NOT
  > migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1 (Settings
  > row "send_test_email" + Auth row "magic-link request").

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
      not Ezagent.AppSettings.mail_configured?() ->
        Mix.shell().error("DROP reason=mail_not_configured")
        Mix.shell().info("→ Admin must configure mail (SMTP or REST) at /admin/settings first.")
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
        Mix.shell().info("→ This email is neither an existing principal nor accepted by")
        Mix.shell().info("  any workspace's magic_link_rule.")
        Mix.shell().info("→ SPEC v2 PR-A/B/C (2026-05-24): registration is now per-workspace.")
        Mix.shell().info("  To allow this email:")
        Mix.shell().info("  (a) Create a workspace at /workspaces and add a domain rule, OR")
        Mix.shell().info("  (b) Programmatically:")

        Mix.shell().info("      Ezagent.Workspace.create(\"#{slug_of_domain(email)}\", %{})")

        Mix.shell().info(
          "      Ezagent.Workspace.add_magic_link_rule(<workspace-uri>, \"domain\", \"#{domain_of(email)}\")"
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
    # SPEC v2 PR-G2 (2026-05-24): align with production
    # `session_controller.send_allowed?/1` — uses `email_allowed?/1`
    # which consults per-workspace `magic_link_rule` rows.
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, _uri} -> true
      :none -> Ezagent.Registration.email_allowed?(email)
    end
  end

  defp domain_of(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> domain
      _ -> "<unknown>"
    end
  end

  # Best-effort: "user@h2oslabs.com" → "h2oslabs" for suggested
  # workspace slug.
  defp slug_of_domain(email) do
    email |> domain_of() |> String.replace(~r/\.[^.]+$/, "")
  end
end
