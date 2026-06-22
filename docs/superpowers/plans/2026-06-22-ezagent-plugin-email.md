# ezagent_plugin_email (CLI-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a self-contained `ezagent_plugin_email` umbrella app exposing a `mix ezagent.email` CLI to send (Swoosh SMTP) and read/delete (CF Email Worker pull API over `:httpc`) mail for `ezagent.chat`.

**Architecture:** A `use Ezagent.Plugin` app whose only runtime declaration is `plugin_info/0`. It owns a facade `Ezagent.Email` (send/inbox/fetch/delete) over its own Swoosh mailer and an `Ezagent.Email.Inbox` backend behaviour (CFWorker now, IMAP reserved). Send reads `smtp_config` from `Ezagent.AppSettings`; receive reads a credentials JSON file via `Ezagent.Email.Config`. A `mix ezagent.email` task is the only entry point — no web/world code.

**Tech Stack:** Elixir/OTP umbrella, Swoosh (SMTP send), `:httpc`+`:inets`/`:ssl` (HTTP pull), Jason, Mix.Task CLI. Cloudflare Email Worker (JS) for the inbound DELETE endpoint.

## Global Constraints

- Branch: `plugin-email` (already created; spec committed there). Do NOT merge to main — Allen merges at the end.
- New umbrella app name: `ezagent_plugin_email` (a real `use Ezagent.Plugin` app).
- No new Hex deps beyond `{:swoosh, "~> 1.17"}` (already used by web). HTTP via Erlang `:httpc` (`:inets`/`:ssl` in `extra_applications`).
- `Ezagent.Mail.SmtpOpts.from_config/1` MUST be a pure map→keyword function in `ezagent_domain_identity`; it MUST NOT add `:swoosh` (or any transport dep) to identity.
- `pull_token` and SMTP password are secrets: never logged, never echoed (CLI may print a masked token at most).
- `:httpc` HTTPS calls pass explicit TLS: `{:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}`.
- Run from `/Users/h2oslabs/Workspace/esr-ng`. Per repo lesson, before trusting per-app failure counts run `mix compile --force` + a clean test DB; the full umbrella run on a clean DB is authoritative.
- Spec: `docs/superpowers/specs/2026-06-22-ezagent-plugin-email-design.md`.

---

## File Structure

- `apps/ezagent_plugin_email/mix.exs` — app + plugin-check compiler + deps (`:swoosh`, core, identity) + `:inets`/`:ssl`.
- `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex` — `use Application` + `use Ezagent.Plugin`; `start/2 → Ezagent.Plugin.boot/1`; `plugin_info/0`.
- `apps/ezagent_plugin_email/lib/ezagent/email.ex` — facade (`send/4`, `inbox/1`, `fetch/2`, `delete/2`).
- `apps/ezagent_plugin_email/lib/ezagent/email/mailer.ex` — `use Swoosh.Mailer, otp_app: :ezagent_plugin_email`.
- `apps/ezagent_plugin_email/lib/ezagent/email/config.ex` — credentials-file + env loader.
- `apps/ezagent_plugin_email/lib/ezagent/email/inbox.ex` — backend behaviour.
- `apps/ezagent_plugin_email/lib/ezagent/email/inbox/cf_worker.ex` — `:httpc` backend (pure URL/JSON + injectable request fun).
- `apps/ezagent_plugin_email/lib/mix/tasks/ezagent.email.ex` — CLI.
- `apps/ezagent_domain_identity/lib/ezagent/mail/smtp_opts.ex` — shared pure SMTP-opts helper.
- `apps/ezagent_web/lib/ezagent_web/mailer.ex` — refactor `smtp_runtime_config/1` to call the helper.
- `apps/ezagent_web/mix.exs`, `mix.exs`, `config/config.exs`, `config/dev.exs`, `config/test.exs` — wiring + mailer adapter config.
- `infra/cf-email-worker/src/worker.js`, `infra/cf-email-worker/README.md` — method-aware DELETE.
- `docs/guide/email-cli.md` (+ `.zh_cn.md`) — operator guide.

---

## Task 1: Scaffold `ezagent_plugin_email` app, plugin contract, and wiring

**Files:**
- Create: `apps/ezagent_plugin_email/mix.exs`
- Create: `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex`
- Create: `apps/ezagent_plugin_email/test/test_helper.exs`
- Create: `apps/ezagent_plugin_email/test/plugin_boot_test.exs`
- Modify: `apps/ezagent_web/mix.exs` (add dep, near line 83-110)
- Modify: `mix.exs` (release applications, near line 44)
- Modify: `config/config.exs` (mailer adapter default, near line 111)
- Modify: `config/dev.exs` (Local adapter, near line 10)
- Modify: `config/test.exs` (Local adapter, near line 78)

**Interfaces:**
- Produces: OTP app `:ezagent_plugin_email`; module `EzagentPluginEmail.Application` with `plugin_info/0` returning `%{slug: "email", name: "Email", description: _, version: "0.1.0"}`.

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_email/test/plugin_boot_test.exs`:
```elixir
defmodule EzagentPluginEmail.PluginBootTest do
  use ExUnit.Case, async: true

  test "plugin_info declares the email slug" do
    info = EzagentPluginEmail.Application.plugin_info()
    assert info.slug == "email"
    assert info.name == "Email"
    assert is_binary(info.version)
  end

  test "the OTP app is loaded" do
    assert {:ezagent_plugin_email, _, _} =
             Enum.find(Application.loaded_applications(), &(elem(&1, 0) == :ezagent_plugin_email))
  end
end
```

`apps/ezagent_plugin_email/test/test_helper.exs`:
```elixir
ExUnit.start()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_email mix test test/plugin_boot_test.exs`
Expected: FAIL — app/module does not exist yet (compile error / unknown application).

- [ ] **Step 3: Create the mix.exs**

`apps/ezagent_plugin_email/mix.exs`:
```elixir
defmodule EzagentPluginEmail.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_email,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginEmail.Application, []},
      env: [ezagent_plugin: EzagentPluginEmail.Application],
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:swoosh, "~> 1.17"},
      # Swoosh's SMTP adapter calls :gen_smtp_client — required for the prod
      # SMTP path (the web mailer declares both; codex plan review MED).
      {:gen_smtp, "~> 1.2"}
    ]
  end
end
```

- [ ] **Step 4: Create the plugin contract module**

`apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex`:
```elixir
defmodule EzagentPluginEmail.Application do
  @moduledoc """
  Email plugin OTP application + `Ezagent.Plugin` contract module
  (task #88, CLI-only). It owns the email capability — `Ezagent.Email`
  send/receive over SMTP (Swoosh) and the CF Email Worker pull API —
  exposed through a `mix ezagent.email` CLI. It registers no
  kinds/behaviors/adapters/surfaces; the plugin body is just
  `plugin_info/0`. A future UI consumer can call `Ezagent.Email`
  without changes here.
  """
  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "email",
      name: "Email",
      description: "Admin CLI for ezagent.chat email send/receive.",
      version: "0.1.0"
    }
  end
end
```

- [ ] **Step 5: Wire into web deps + release + mailer config**

In `apps/ezagent_web/mix.exs`, alongside the other plugin deps (after line 110 `{:ezagent_plugin_advisor, in_umbrella: true},`) add:
```elixir
      {:ezagent_plugin_email, in_umbrella: true},
```

In `mix.exs`, in the `releases/0` applications list (after `ezagent_plugin_advisor: :permanent,`, line 41) add:
```elixir
          ezagent_plugin_email: :permanent,
```

In `config/config.exs` (after line 111) add:
```elixir
config :ezagent_plugin_email, Ezagent.Email.Mailer, adapter: Swoosh.Adapters.SMTP
```

In `config/dev.exs` (after line 10) add:
```elixir
config :ezagent_plugin_email, Ezagent.Email.Mailer, adapter: Swoosh.Adapters.Local
```

In `config/test.exs` (after line 78) add (codex plan review HIGH — use the
**Test** adapter, not Local, so `Swoosh.TestAssertions.assert_email_sent` fires;
`assert_email_sent` only works with `Swoosh.Adapters.Test`, which delivers an
`{:email, _}` message to the test process):
```elixir
config :ezagent_plugin_email, Ezagent.Email.Mailer, adapter: Swoosh.Adapters.Test
```

- [ ] **Step 6: Run tests + wired-to-web invariant + plugin-check**

Run: `mix deps.get && mix compile --force`
Expected: compiles; `:ezagent_plugin_check` passes for the new plugin.

Run: `mix cmd --app ezagent_plugin_email mix test test/plugin_boot_test.exs`
Expected: PASS (2 tests).

Run: `mix cmd --app ezagent_core mix test test/invariants/all_plugin_apps_wired_to_web_test.exs`
Expected: PASS (the new app is in web deps).

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_plugin_email apps/ezagent_web/mix.exs mix.exs config/config.exs config/dev.exs config/test.exs
git commit -m "feat(email): scaffold ezagent_plugin_email app + plugin contract + wiring"
```

---

## Task 2: Extract pure `Ezagent.Mail.SmtpOpts.from_config/1` and refactor the web mailer onto it

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/mail/smtp_opts.ex`
- Create: `apps/ezagent_domain_identity/test/mail/smtp_opts_test.exs`
- Modify: `apps/ezagent_web/lib/ezagent_web/mailer.ex` (replace `smtp_runtime_config/1` body + `tls_options/1` + `to_int/1`, lines ~190-234)

**Interfaces:**
- Produces: `Ezagent.Mail.SmtpOpts.from_config/1 :: (map()) -> keyword()` — maps a stored `smtp_config` (`%{"host","port","username","password","from_address"?,"tls"?}`) to `Swoosh.Adapters.SMTP` options (relay/port/username/password/auth/tls_options + ssl/tls per 465-vs-587). Consumed by both mailers.

- [ ] **Step 1: Write the failing test**

`apps/ezagent_domain_identity/test/mail/smtp_opts_test.exs`:
```elixir
defmodule Ezagent.Mail.SmtpOptsTest do
  use ExUnit.Case, async: true
  alias Ezagent.Mail.SmtpOpts

  @base %{"host" => "smtp.example.com", "username" => "u", "password" => "p"}

  test "port 465 → implicit SSL (ssl: true, tls: :never)" do
    opts = SmtpOpts.from_config(Map.put(@base, "port", "465"))
    assert opts[:relay] == "smtp.example.com"
    assert opts[:port] == 465
    assert opts[:ssl] == true
    assert opts[:tls] == :never
    assert opts[:auth] == :always
    assert is_list(opts[:tls_options])
    assert opts[:tls_options][:verify] == :verify_peer
  end

  test "port 587 → STARTTLS (ssl: false, tls: :always by default)" do
    opts = SmtpOpts.from_config(Map.put(@base, "port", 587))
    assert opts[:ssl] == false
    assert opts[:tls] == :always
  end

  test "port 587 with tls: false → tls: :never" do
    opts = SmtpOpts.from_config(@base |> Map.put("port", 587) |> Map.put("tls", false))
    assert opts[:tls] == :never
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_domain_identity mix test test/mail/smtp_opts_test.exs`
Expected: FAIL — `Ezagent.Mail.SmtpOpts` undefined.

- [ ] **Step 3: Create the pure helper**

`apps/ezagent_domain_identity/lib/ezagent/mail/smtp_opts.ex`:
```elixir
defmodule Ezagent.Mail.SmtpOpts do
  @moduledoc """
  Pure mapping from a stored `smtp_config` map to `Swoosh.Adapters.SMTP`
  options. Shared by `EzagentWeb.Mailer` and `Ezagent.Email.Mailer` so the
  OTP 27/28 TLS handling lives in exactly one place.

  Lives in `ezagent_domain_identity` (where `Ezagent.AppSettings` stores
  `smtp_config`). It is a pure function and MUST NOT depend on `:swoosh` or
  any transport — it only shapes an options keyword list.

  Port semantics: 465 → implicit SSL (`ssl: true, tls: :never`); 587 (and
  other non-465) → STARTTLS (`ssl: false`, `tls: :always` unless `tls: false`).
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
```

- [ ] **Step 4: Refactor the web mailer to delegate**

In `apps/ezagent_web/lib/ezagent_web/mailer.ex`, replace the private `smtp_runtime_config/1`, `tls_options/1`, and `to_int/1` (lines ~190-234) with a single delegating clause:
```elixir
  # SMTP option mapping lives in the shared pure helper so the OTP 27/28 TLS
  # handling is not duplicated (task #88).
  defp smtp_runtime_config(cfg), do: Ezagent.Mail.SmtpOpts.from_config(cfg)
```
Keep the surrounding `deliver_built/1` call site (`deliver(email, smtp_runtime_config(...))`) unchanged.

- [ ] **Step 5: Run tests**

Run: `mix cmd --app ezagent_domain_identity mix test test/mail/smtp_opts_test.exs`
Expected: PASS (3 tests).

Run: `mix cmd --app ezagent_web mix test test/ezagent_web/mailer_test.exs` (if present) and `mix cmd --app ezagent_web mix compile --force`
Expected: compiles; existing mailer tests still PASS (regression — same opts).

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_identity/lib/ezagent/mail apps/ezagent_domain_identity/test/mail apps/ezagent_web/lib/ezagent_web/mailer.ex
git commit -m "refactor(mail): extract pure Ezagent.Mail.SmtpOpts shared by both mailers"
```

---

## Task 3: `Ezagent.Email.Mailer` + `Ezagent.Email.send/4`

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/mailer.ex`
- Create: `apps/ezagent_plugin_email/lib/ezagent/email.ex`
- Create: `apps/ezagent_plugin_email/test/email_send_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Mail.SmtpOpts.from_config/1` (Task 2); `Ezagent.AppSettings.get/1`, `Ezagent.AppSettings.smtp_configured?/0` (identity).
- Produces: `Ezagent.Email.send(to, subject, body, opts \\ []) :: {:ok, term()} | {:error, term()}` (opts: `:from`, `:html`). `Ezagent.Email.Mailer` (Swoosh mailer module).

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_email/test/email_send_test.exs`:
```elixir
defmodule Ezagent.EmailSendTest do
  use ExUnit.Case, async: false
  import Swoosh.TestAssertions

  setup do
    # Local adapter is configured in config/test.exs; ensure inbox is clean.
    :ok
  end

  test "send/4 delivers via the Local adapter in test" do
    assert {:ok, _} =
             Ezagent.Email.send("dest@ezagent.chat", "Hi", "body text",
               from: "no-reply@ezagent.chat")

    assert_email_sent(fn email ->
      assert {_, "dest@ezagent.chat"} = hd(email.to)
      assert email.subject == "Hi"
      assert email.text_body == "body text"
    end)
  end

  test "send/4 includes html body when given" do
    {:ok, _} = Ezagent.Email.send("d@ezagent.chat", "S", "t", html: "<p>t</p>")
    assert_email_sent(fn email -> assert email.html_body == "<p>t</p>" end)
  end
end
```

(Swoosh ships `Swoosh.TestAssertions`; the Local adapter records into the test process mailbox.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_email mix test test/email_send_test.exs`
Expected: FAIL — `Ezagent.Email` undefined.

- [ ] **Step 3: Create the mailer**

`apps/ezagent_plugin_email/lib/ezagent/email/mailer.ex`:
```elixir
defmodule Ezagent.Email.Mailer do
  @moduledoc """
  Swoosh mailer for the email plugin. Adapter is fixed per env:
  `Swoosh.Adapters.Local` in dev/test (always ready), `Swoosh.Adapters.SMTP`
  in prod (needs the runtime `smtp_config` from `Ezagent.AppSettings`).
  """
  use Swoosh.Mailer, otp_app: :ezagent_plugin_email
end
```

- [ ] **Step 4: Create the facade send path**

`apps/ezagent_plugin_email/lib/ezagent/email.ex`:
```elixir
defmodule Ezagent.Email do
  @moduledoc """
  Facade for ezagent.chat email (task #88, CLI-only). `send/4` goes out over
  SMTP (Swoosh, `smtp_config` from `Ezagent.AppSettings`); inbox/fetch/delete
  read the configured inbox backend (Task 5).
  """
  import Swoosh.Email
  alias Ezagent.Email.Mailer

  @default_from "no-reply@ezagent.chat"

  @spec send(String.t(), String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send(to, subject, body, opts \\ [])
      when is_binary(to) and is_binary(subject) and is_binary(body) do
    if mail_ready?() do
      from = Keyword.get(opts, :from) || configured_from()

      email =
        new()
        |> to(to)
        |> from({"Ezagent", from})
        |> subject(subject)
        |> text_body(body)
        |> maybe_html(opts[:html])

      deliver_built(email)
    else
      {:error, :mail_not_configured}
    end
  end

  defp maybe_html(email, nil), do: email
  defp maybe_html(email, html) when is_binary(html), do: html_body(email, html)

  defp configured_adapter, do: Application.get_env(:ezagent_plugin_email, Mailer, [])[:adapter]

  # Local (dev) and Test (test) adapters are "non-SMTP": always ready and they
  # do NOT touch the DB. Only the SMTP adapter reads smtp_config from AppSettings.
  # (codex plan review HIGH — keep test/CLI-Local paths off the Repo sandbox.)
  defp non_smtp_adapter? do
    configured_adapter() in [Swoosh.Adapters.Local, Swoosh.Adapters.Test]
  end

  defp mail_ready? do
    if non_smtp_adapter?(), do: true, else: Ezagent.AppSettings.smtp_configured?()
  end

  defp configured_from do
    if non_smtp_adapter?() do
      @default_from
    else
      case Ezagent.AppSettings.get("smtp_config") do
        %{"from_address" => addr} when is_binary(addr) and addr != "" -> addr
        _ -> @default_from
      end
    end
  end

  defp deliver_built(email) do
    if non_smtp_adapter?() do
      Mailer.deliver(email)
    else
      Mailer.deliver(email, Ezagent.Mail.SmtpOpts.from_config(Ezagent.AppSettings.get("smtp_config")))
    end
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix cmd --app ezagent_plugin_email mix test test/email_send_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_email/lib/ezagent/email.ex apps/ezagent_plugin_email/lib/ezagent/email/mailer.ex apps/ezagent_plugin_email/test/email_send_test.exs
git commit -m "feat(email): Ezagent.Email.send/4 over Swoosh SMTP"
```

---

## Task 4: `Ezagent.Email.Config` — credentials file + env override

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/config.ex`
- Create: `apps/ezagent_plugin_email/test/config_test.exs`

**Interfaces:**
- Consumes: `Ezagent.System.FsResolver.path!/1`, `Ezagent.URI.system/2` (core).
- Produces: `Ezagent.Email.Config.load/0 :: {:ok, %{"backend"=>String.t(),"pull_url"=>String.t(),"pull_token"=>String.t()}} | {:error, :inbox_not_configured}`. Env overrides: `EZAGENT_EMAIL_PULL_URL`, `EZAGENT_EMAIL_PULL_TOKEN`, `EZAGENT_EMAIL_BACKEND`.

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_email/test/config_test.exs`:
```elixir
defmodule Ezagent.Email.ConfigTest do
  use ExUnit.Case, async: false
  alias Ezagent.Email.Config

  setup do
    on_exit(fn ->
      System.delete_env("EZAGENT_EMAIL_PULL_URL")
      System.delete_env("EZAGENT_EMAIL_PULL_TOKEN")
      System.delete_env("EZAGENT_EMAIL_BACKEND")
    end)
  end

  test "env vars supply config when file is absent" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    assert {:ok, cfg} = Config.load()
    assert cfg["pull_url"] == "https://w.example.dev"
    assert cfg["pull_token"] == "tok"
    assert cfg["backend"] == "cf_worker"
  end

  test "blank/missing config → :inbox_not_configured" do
    # No env, and (in test) no credentials file present.
    assert {:error, :inbox_not_configured} = Config.load()
  end

  test "backend env override is honored" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    System.put_env("EZAGENT_EMAIL_BACKEND", "imap")
    assert {:ok, %{"backend" => "imap"}} = Config.load()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_email mix test test/config_test.exs`
Expected: FAIL — `Ezagent.Email.Config` undefined.

- [ ] **Step 3: Create the config loader**

`apps/ezagent_plugin_email/lib/ezagent/email/config.ex`:
```elixir
defmodule Ezagent.Email.Config do
  @moduledoc """
  Loads the inbound-email pull config for the CLI. Reads
  `<credentials>/email_inbox_config.json` (same `system://credentials/...`
  location as `smtp_config.json`), with env-var overrides. Returns
  `{:error, :inbox_not_configured}` unless a non-blank `pull_url` + `pull_token`
  are present. The token is read from disk/env only — never logged or echoed.
  """

  @spec load() :: {:ok, map()} | {:error, :inbox_not_configured}
  def load do
    file = read_file()

    cfg = %{
      "backend" => env("EZAGENT_EMAIL_BACKEND") || Map.get(file, "backend") || "cf_worker",
      "pull_url" => env("EZAGENT_EMAIL_PULL_URL") || Map.get(file, "pull_url") || "",
      "pull_token" => env("EZAGENT_EMAIL_PULL_TOKEN") || Map.get(file, "pull_token") || ""
    }

    if blank?(cfg["pull_url"]) or blank?(cfg["pull_token"]) do
      {:error, :inbox_not_configured}
    else
      {:ok, cfg}
    end
  end

  defp read_file do
    with {:ok, path} <- safe_path(),
         {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(body) do
      json
    else
      _ -> %{}
    end
  end

  defp safe_path do
    {:ok, Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "email_inbox_config.json"))}
  rescue
    _ -> :error
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
end
```

- [ ] **Step 4: Run tests**

Run: `mix cmd --app ezagent_plugin_email mix test test/config_test.exs`
Expected: PASS (3 tests).

(If the "blank" test fails because a real `email_inbox_config.json` exists in the dev credentials dir, the test is still correct for CI/clean checkouts; note it and rely on the clean-DB/full-suite run. Do not weaken the assertion.)

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_email/lib/ezagent/email/config.ex apps/ezagent_plugin_email/test/config_test.exs
git commit -m "feat(email): credentials-file + env inbox config loader"
```

---

## Task 5: `Ezagent.Email.Inbox` behaviour + `CFWorker` backend + facade inbox/fetch/delete

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/inbox.ex`
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/inbox/cf_worker.ex`
- Modify: `apps/ezagent_plugin_email/lib/ezagent/email.ex` (add inbox/1, fetch/2, delete/2)
- Create: `apps/ezagent_plugin_email/test/inbox_cf_worker_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Email.Config.load/0` (Task 4).
- Produces:
  - Behaviour `Ezagent.Email.Inbox` with `list(config, opts)`, `fetch(config, key)`, `delete(config, key)`.
  - `Ezagent.Email.Inbox.CFWorker` implementing it via `:httpc`, with a pure `build/3` returning `{method, url, headers}` and pure `decode_list/1` / `decode_one/1`. The raw request goes through `request_fun/0` = `Application.get_env(:ezagent_plugin_email, :http_request_fun, &:httpc.request/4)` so tests inject canned responses.
  - Facade `Ezagent.Email.inbox(opts) :: {:ok, [map()]} | {:error, term()}`, `fetch(key, opts) :: {:ok, map()} | {:error, :not_found | term()}`, `delete(key, opts) :: :ok | {:error, term()}`.

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_email/test/inbox_cf_worker_test.exs`:
```elixir
defmodule Ezagent.Email.Inbox.CFWorkerTest do
  use ExUnit.Case, async: false
  alias Ezagent.Email.Inbox.CFWorker

  @cfg %{"backend" => "cf_worker", "pull_url" => "https://w.example.dev", "pull_token" => "tok"}

  defp stub(fun) do
    Application.put_env(:ezagent_plugin_email, :http_request_fun, fun)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_email, :http_request_fun) end)
  end

  test "list builds GET /inbox with bearer + ?to= and decodes records" do
    stub(fn :get, {url, headers}, _http_opts, _opts ->
      assert url == ~c"https://w.example.dev/inbox?to=a%40ezagent.chat"
      assert {~c"authorization", ~c"Bearer tok"} in headers
      body = Jason.encode!(%{"count" => 1, "emails" => [%{"key" => "k1", "subject" => "S"}]})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], String.to_charlist(body)}}
    end)

    assert {:ok, [%{"key" => "k1", "subject" => "S"}]} = CFWorker.list(@cfg, to: "a@ezagent.chat")
  end

  test "delete issues DELETE /inbox/<key> and returns :ok on 204" do
    stub(fn :delete, {url, headers}, _http_opts, _opts ->
      assert url == ~c"https://w.example.dev/inbox/k1"
      assert {~c"authorization", ~c"Bearer tok"} in headers
      {:ok, {{~c"HTTP/1.1", 204, ~c"No Content"}, [], ~c""}}
    end)

    assert :ok = CFWorker.delete(@cfg, "k1")
  end

  test "non-2xx maps to {:error, {:http, status}}" do
    stub(fn :get, _req, _http_opts, _opts ->
      {:ok, {{~c"HTTP/1.1", 500, ~c"err"}, [], ~c"boom"}}
    end)

    assert {:error, {:http, 500}} = CFWorker.list(@cfg, [])
  end

  test "fetch 404 maps to :not_found" do
    stub(fn :get, _req, _http_opts, _opts ->
      {:ok, {{~c"HTTP/1.1", 404, ~c"nf"}, [], ~c"not found"}}
    end)

    assert {:error, :not_found} = CFWorker.fetch(@cfg, "missing")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_email mix test test/inbox_cf_worker_test.exs`
Expected: FAIL — `Ezagent.Email.Inbox.CFWorker` undefined.

- [ ] **Step 3: Create the behaviour**

`apps/ezagent_plugin_email/lib/ezagent/email/inbox.ex`:
```elixir
defmodule Ezagent.Email.Inbox do
  @moduledoc """
  Backend behaviour for reading inbound mail. `CFWorker` (HTTP pull from the
  Cloudflare Email Worker) is the only impl this round; an `Imap` backend is
  reserved (`backend: "imap"`).
  """
  @callback list(config :: map(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch(config :: map(), key :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback delete(config :: map(), key :: String.t()) :: :ok | {:error, term()}
end
```

- [ ] **Step 4: Create the CFWorker backend**

`apps/ezagent_plugin_email/lib/ezagent/email/inbox/cf_worker.ex`:
```elixir
defmodule Ezagent.Email.Inbox.CFWorker do
  @moduledoc """
  `Ezagent.Email.Inbox` backend that pulls from the Cloudflare Email Worker's
  HTTP API (`GET /inbox[?to=]`, `GET /inbox/<key>`, `DELETE /inbox/<key>`),
  authenticating with `Authorization: Bearer <pull_token>`. URL building and
  JSON decoding are pure; the raw `:httpc` call is injectable for tests via
  `:http_request_fun` app env.
  """
  @behaviour Ezagent.Email.Inbox

  @impl true
  def list(config, opts) do
    {method, url, headers} = build(config, {:list, Keyword.get(opts, :to)})

    case do_request(method, url, headers) do
      {:ok, 200, body} -> {:ok, decode_list(body)}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(config, key) do
    {method, url, headers} = build(config, {:fetch, key})

    case do_request(method, url, headers) do
      {:ok, 200, body} -> {:ok, decode_one(body)}
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(config, key) do
    {method, url, headers} = build(config, {:delete, key})

    case do_request(method, url, headers) do
      {:ok, status, _} when status in [200, 204] -> :ok
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- pure helpers (unit-tested) ------------------------------------------

  @doc false
  def build(%{"pull_url" => base, "pull_token" => token}, op) do
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case op do
      {:list, nil} -> {:get, url(base, "/inbox"), headers}
      {:list, to} -> {:get, url(base, "/inbox?to=" <> URI.encode_www_form(to)), headers}
      {:fetch, key} -> {:get, url(base, "/inbox/" <> URI.encode(key)), headers}
      {:delete, key} -> {:delete, url(base, "/inbox/" <> URI.encode(key)), headers}
    end
  end

  defp url(base, path), do: String.to_charlist(String.trim_trailing(base, "/") <> path)

  @doc false
  def decode_list(body) do
    case Jason.decode(body) do
      {:ok, %{"emails" => emails}} when is_list(emails) -> emails
      _ -> []
    end
  end

  @doc false
  def decode_one(body) do
    case Jason.decode(body) do
      {:ok, %{} = rec} -> rec
      _ -> %{}
    end
  end

  # --- impure transport (injectable) ---------------------------------------

  defp do_request(method, url, headers) do
    http_opts = [
      {:timeout, 15_000},
      {:connect_timeout, 10_000},
      {:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]

    request =
      case method do
        :get -> {url, headers}
        :delete -> {url, headers}
      end

    case request_fun().(method, request, http_opts, []) do
      {:ok, {{_, status, _}, _headers, body}} -> {:ok, status, to_string(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_fun, do: Application.get_env(:ezagent_plugin_email, :http_request_fun, &:httpc.request/4)
end
```

- [ ] **Step 5: Extend the facade**

Add to `apps/ezagent_plugin_email/lib/ezagent/email.ex`:
```elixir
  @spec inbox(keyword()) :: {:ok, [map()]} | {:error, term()}
  def inbox(opts \\ []), do: with_backend(&backend().list(&1, opts))

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(key, _opts \\ []) when is_binary(key), do: with_backend(&backend().fetch(&1, key))

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, _opts \\ []) when is_binary(key), do: with_backend(&backend().delete(&1, key))

  defp with_backend(fun) do
    case Ezagent.Email.Config.load() do
      {:ok, %{"backend" => "cf_worker"} = cfg} -> fun.(cfg)
      {:ok, %{"backend" => other}} when other != "cf_worker" -> {:error, :backend_not_implemented}
      {:error, _} = err -> err
    end
  end

  defp backend, do: Ezagent.Email.Inbox.CFWorker
```

Add a test for the backend-seam in `test/inbox_cf_worker_test.exs`:
```elixir
  test "facade returns :backend_not_implemented for a non-cf backend" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    System.put_env("EZAGENT_EMAIL_BACKEND", "imap")
    on_exit(fn ->
      System.delete_env("EZAGENT_EMAIL_PULL_URL")
      System.delete_env("EZAGENT_EMAIL_PULL_TOKEN")
      System.delete_env("EZAGENT_EMAIL_BACKEND")
    end)

    assert {:error, :backend_not_implemented} = Ezagent.Email.inbox([])
  end
```

- [ ] **Step 6: Run tests**

Run: `mix cmd --app ezagent_plugin_email mix test test/inbox_cf_worker_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_plugin_email/lib/ezagent/email/inbox.ex apps/ezagent_plugin_email/lib/ezagent/email/inbox/cf_worker.ex apps/ezagent_plugin_email/lib/ezagent/email.ex apps/ezagent_plugin_email/test/inbox_cf_worker_test.exs
git commit -m "feat(email): inbox backend behaviour + CFWorker (:httpc) + facade inbox/fetch/delete"
```

---

## Task 6: `mix ezagent.email` CLI

**Files:**
- Create: `apps/ezagent_plugin_email/lib/mix/tasks/ezagent.email.ex`
- Create: `apps/ezagent_plugin_email/test/cli_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Email.send/4`, `inbox/1`, `fetch/2`, `delete/2`.
- Produces: `mix ezagent.email send|inbox|fetch|delete` (see usage in the moduledoc below).

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_email/test/cli_test.exs`:
```elixir
defmodule Mix.Tasks.Ezagent.EmailTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "send subcommand calls Ezagent.Email.send and prints ok" do
    # Local adapter (test config) makes send succeed without SMTP config.
    out =
      capture_io(fn ->
        Mix.Tasks.Ezagent.Email.run(["send", "--to", "d@ezagent.chat", "--subject", "S", "--body", "B"])
      end)

    assert out =~ "sent"
  end

  test "inbox subcommand prints the not-configured reason when unset" do
    out =
      capture_io(fn ->
        assert catch_exit(Mix.Tasks.Ezagent.Email.run(["inbox"])) == {:shutdown, 1}
      end)

    assert out =~ "inbox_not_configured"
  end
end
```

(The task calls `System.halt`-free exit via `exit({:shutdown, 1})` on error so it is testable; see impl.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_email mix test test/cli_test.exs`
Expected: FAIL — task module undefined.

- [ ] **Step 3: Create the CLI task**

`apps/ezagent_plugin_email/lib/mix/tasks/ezagent.email.ex`:
```elixir
defmodule Mix.Tasks.Ezagent.Email do
  @shortdoc "Send / read / delete ezagent.chat email (task #88)"
  @moduledoc """
  Operator CLI for ezagent.chat email. Runs in-VM (trusted boundary).

      mix ezagent.email send --to <addr> --subject <s> --body <b> [--html <h>]
      mix ezagent.email inbox [--to <addr>] [--limit N]
      mix ezagent.email fetch <key>
      mix ezagent.email delete <key>

  Send uses SMTP (`smtp_config` in AppSettings). Inbox/fetch/delete read
  `<credentials>/email_inbox_config.json` (or `EZAGENT_EMAIL_PULL_URL` /
  `EZAGENT_EMAIL_PULL_TOKEN`).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_email)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [to: :string, subject: :string, body: :string, html: :string, limit: :integer]
      )

    case positional do
      ["send" | _] -> do_send(opts)
      ["inbox" | _] -> do_inbox(opts)
      ["fetch", key | _] -> do_fetch(key)
      ["delete", key | _] -> do_delete(key)
      _ -> fail("usage: see `mix help ezagent.email`")
    end
  end

  defp do_send(opts) do
    to = req(opts, :to)
    subject = req(opts, :subject)
    body = req(opts, :body)

    case Ezagent.Email.send(to, subject, body, Keyword.take(opts, [:html])) do
      {:ok, _} -> Mix.shell().info("sent to #{to}")
      {:error, reason} -> fail("send failed: #{inspect(reason)}")
    end
  end

  defp do_inbox(opts) do
    case Ezagent.Email.inbox(Keyword.take(opts, [:to, :limit])) do
      {:ok, emails} ->
        Mix.shell().info("#{length(emails)} message(s):")
        Enum.each(emails, fn e ->
          Mix.shell().info("  #{e["key"]}  | #{e["from"]} | #{e["subject"]} | #{e["receivedAt"]}")
        end)

      {:error, reason} ->
        fail("inbox failed: #{inspect(reason)}")
    end
  end

  defp do_fetch(key) do
    case Ezagent.Email.fetch(key) do
      {:ok, e} -> Mix.shell().info("From: #{e["from"]}\nTo: #{e["to"]}\nSubject: #{e["subject"]}\n\n#{e["text"]}")
      {:error, reason} -> fail("fetch failed: #{inspect(reason)}")
    end
  end

  defp do_delete(key) do
    case Ezagent.Email.delete(key) do
      :ok -> Mix.shell().info("deleted #{key}")
      {:error, reason} -> fail("delete failed: #{inspect(reason)}")
    end
  end

  defp req(opts, k) do
    case Keyword.get(opts, k) do
      nil -> fail("missing --#{k}")
      v -> v
    end
  end

  defp fail(msg) do
    Mix.shell().error(msg)
    exit({:shutdown, 1})
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix cmd --app ezagent_plugin_email mix test test/cli_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_email/lib/mix/tasks/ezagent.email.ex apps/ezagent_plugin_email/test/cli_test.exs
git commit -m "feat(email): mix ezagent.email CLI (send/inbox/fetch/delete)"
```

---

## Task 7: Worker `DELETE /inbox/<key>` (method-aware) + README + redeploy

**Files:**
- Modify: `infra/cf-email-worker/src/worker.js` (fetch handler)
- Modify: `infra/cf-email-worker/README.md`

**Interfaces:**
- Produces: `DELETE /inbox/<key>` → 204; `GET` list/fetch unchanged; other methods → 405.

- [ ] **Step 1: Rewrite the fetch handler to route by `{method, pathname}`**

Replace the body of `async fetch(request, env)` after the auth check in `infra/cf-email-worker/src/worker.js` with:
```javascript
    const url = new URL(request.url);
    const method = request.method;

    if (url.pathname === "/inbox" && method === "GET") {
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
      if (method === "GET") {
        const v = await env.EMAIL_INBOX.get(key);
        if (!v) return new Response("not found\n", { status: 404 });
        return new Response(v, { headers: { "content-type": "application/json" } });
      }
      if (method === "DELETE") {
        await env.EMAIL_INBOX.delete(key);
        return new Response(null, { status: 204 });
      }
      return new Response("method not allowed\n", { status: 405 });
    }

    return new Response(
      "ezagent inbound email cache.\n  GET /inbox[?to=<addr>] — list\n  GET /inbox/<key> — one message\n  DELETE /inbox/<key> — delete one\n(Authorization: Bearer <token>)\n",
      { headers: { "content-type": "text/plain" } }
    );
```

- [ ] **Step 2: Update the README**

In `infra/cf-email-worker/README.md`, under the Pull API list (lines 16-20), add:
```markdown
- `DELETE /inbox/<key>` — delete one cached message (204)
```

- [ ] **Step 3: Redeploy + verify (operator/live step — flagged)**

> **USER-ASSIST / live step:** this touches the live Cloudflare account. Run with the CF token at `/tmp/.cf_token_task87` and the pull token at `/tmp/.pull_token` (kept out of repo).
```bash
cd infra/cf-email-worker
CLOUDFLARE_API_TOKEN=$(tr -d '\n' </tmp/.cf_token_task87) \
CLOUDFLARE_ACCOUNT_ID=ec413d68e6a97533c1dc819c90a106e3 \
  wrangler deploy
# verify: list, delete the test key, re-list shows it gone
PULL=$(tr -d '\n' </tmp/.pull_token)
curl -s -H "Authorization: Bearer $PULL" https://ezagent-email-inbox.allenwoods.workers.dev/inbox
curl -s -X DELETE -H "Authorization: Bearer $PULL" "https://ezagent-email-inbox.allenwoods.workers.dev/inbox/<key>"
```
Expected: DELETE returns 204; the key disappears from the subsequent list.

- [ ] **Step 4: Commit**

```bash
git add infra/cf-email-worker/src/worker.js infra/cf-email-worker/README.md
git commit -m "feat(cf-email-worker): method-aware routing + DELETE /inbox/<key>"
```

---

## Task 8: Operator guide + full gates

**Files:**
- Create: `docs/guide/email-cli.md`
- Create: `docs/guide/email-cli.zh_cn.md`

- [ ] **Step 1: Write the bilingual operator guide**

`docs/guide/email-cli.md` — cover: what the tool is (CLI-only admin email for ezagent.chat); the `email_inbox_config.json` location + fields + env overrides; the four subcommands with examples; that send needs `smtp_config` (admin SMTP settings) and receive needs the worker pull config; the IMAP-backend-reserved note. `docs/guide/email-cli.zh_cn.md` — the parallel Chinese version.

- [ ] **Step 2: Run the full gate suite**

```bash
mix compile --force
mix test
mix cmd --app ezagent_core mix test test/invariants/
```
Expected: full umbrella `mix test` 0 failures (on a clean test DB — reset if drifted); all invariant suites green, including `all_plugin_apps_wired_to_web_test`. Then run the repo's arch / uri_query / doc / format gates (per CONTRIBUTING) and confirm green.

- [ ] **Step 3: Commit**

```bash
git add docs/guide/email-cli.md docs/guide/email-cli.zh_cn.md
git commit -m "docs(email): operator CLI guide (bilingual)"
```

---

## Self-Review

**1. Spec coverage:**
- §4.1 facade → Tasks 3, 5. §4.2 mailer + SmtpOpts → Tasks 2, 3. §4.3 inbox behaviour + CFWorker + TLS → Task 5. §4.4 Config (creds file + env) → Task 4. §4.5 CLI → Task 6. §4.6 plugin + boot wiring → Task 1. §4.6 worker DELETE → Task 7. §6 authz (CLI-only, no web gate) → satisfied by construction. §7 error tuples → Tasks 3/5/6. §8 testing → each task's tests. §9 gates (acyclic, boot wiring, :inets/:ssl, check_invariants) → Tasks 1, 8. §10 out-of-scope (no UI / no session-ingest / IMAP seam only) → respected.
- Gap check: none outstanding.

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. The one conditional note (Task 4 Step 4) explicitly says do not weaken the assertion.

**3. Type consistency:** `Ezagent.Mail.SmtpOpts.from_config/1` (Task 2) used identically in Task 3. `Ezagent.Email.Config.load/0` returns `{:ok, map}|{:error, :inbox_not_configured}` (Task 4), consumed by the facade `with_backend/1` (Task 5). `CFWorker.build/3` + `decode_list/1` + `decode_one/1` + `:http_request_fun` injection consistent across impl and tests (Task 5). Facade `inbox/1`/`fetch/2`/`delete/2` signatures match the CLI calls (Task 6). Worker `DELETE` shape (Task 7) matches `CFWorker.delete/2` expectations (204→`:ok`).
