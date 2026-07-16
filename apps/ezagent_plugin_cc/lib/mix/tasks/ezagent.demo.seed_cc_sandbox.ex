defmodule Mix.Tasks.Ezagent.Demo.SeedCcSandbox do
  @shortdoc "Seed a cc agent sandbox dir + copy host credentials (avoid re-login)"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (filesystem + demo seeder).**
  > Intentionally NOT a dispatched op. The dominant work is host-side
  > filesystem prep (mkdir / chmod / copy of `~/.claude/.credentials.json`
  > with 700/600 modes). The optional `--seed-template` step DOES go
  > through `Ezagent.Invocation.dispatch` for the `template.write`
  > action. Stays as `mix ezagent.*`; do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1 (this
  > task is not in the audit matrix — it's a credential-bootstrap helper).

  Create a sandbox `CLAUDE_CONFIG_DIR` for a cc agent, copy the
  operator's authenticated `~/.claude/.credentials.json` into it, and
  (optionally) seed an `AgentTemplate` pointing at the sandbox.

  Allen Feishu 2026-05-23 — V1 sign-off for the credential-copy flow:

  > 使用 sandbox 模式是否可以加载保存在本地的 credentials
  > (从 ~/.claude/ 中复制过去), 避免要求用户反复登录.

  The cc Template Class sets `CLAUDE_CONFIG_DIR=<sandbox>` on the
  spawned `claude` process, which then looks ONLY in `<sandbox>` for
  credentials — NOT the host `~/.claude/`. Pre-seeding the sandbox
  with the operator's authenticated credentials file avoids forcing
  a fresh `claude login` for every new agent.

  ## Usage

      mix ezagent.demo.seed_cc_sandbox --name my-agent

      # Custom sandbox dir
      mix ezagent.demo.seed_cc_sandbox --name my-agent \\
        --sandbox-dir /opt/cc-sandboxes/my-agent

      # Custom source credentials (not the host default)
      mix ezagent.demo.seed_cc_sandbox --name my-agent \\
        --credentials-file /path/to/.credentials.json

      # Overwrite an existing sandbox credentials file
      mix ezagent.demo.seed_cc_sandbox --name my-agent --force

      # Also seed an AgentTemplate pointing at the sandbox
      mix ezagent.demo.seed_cc_sandbox --name my-agent \\
        --seed-template my-agent

  ## Flags

  | Flag | Default | Meaning |
  |---|---|---|
  | `--name <s>` | required | logical sandbox name (used in default sandbox path + template URI) |
  | `--sandbox-dir <p>` | `~/.ezagent/cc-sandboxes/<name>` | absolute path for the sandbox |
  | `--credentials-file <p>` | `~/.claude/.credentials.json` | source credentials to copy |
  | `--force` | `false` | overwrite `<sandbox>/.credentials.json` if it already exists |
  | `--seed-template <s>` | (none) | also dispatch `AgentTemplate` `:write` for `template://agent/system/cc-<s>` pointing at the sandbox |

  ## Failure modes (operator-friendly)

  | Condition | Behavior |
  |---|---|
  | source credentials file missing | hard error: "no host credentials to copy — `claude login` first, or pass `--credentials-file <path>`" |
  | `<sandbox>/.credentials.json` exists, no `--force` | hard error: refuses to clobber; tells operator to pass `--force` |
  | sandbox dir parent unwritable | mkdir fails loudly |
  | macOS Keychain has the creds (not the file) | source-missing error; runbook explains the `api_key_helper` workaround |

  ## Permissions

  The sandbox dir is created with `chmod 700`; the credentials file is
  copied with `chmod 600` (same posture as `~/.ezagent/smtp_config.local.json`).

  ## See also

  - `docs/runbook/cc-agent-e2e.md` — the full operator runbook
    including the macOS Keychain caveat.
  - `docs/runbook/cc-agent-config.md` — the AgentTemplate slice schema.
  - `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
    — the e2e proving the file-layout + env-threading contract.
  """
  use Mix.Task

  @switches [
    name: :string,
    sandbox_dir: :string,
    credentials_file: :string,
    force: :boolean,
    seed_template: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, switches: @switches)

    name = opts[:name] || Mix.raise("--name <name> is required")
    sandbox_dir = opts[:sandbox_dir] || default_sandbox_dir(name)
    # P2.5b/§5.B(c) — NORMALIZE to an absolute path at the seed boundary (codex
    # #719 MEDIUM): `source` is both copied now AND persisted into the template's
    # `credential_source` -> respawn_template_data. A relative path would copy OK
    # under the mix task cwd but later resolve under the RUNTIME cwd on respawn,
    # degrading the credential refresh to a stale no-op. Path.expand makes the
    # durable value cwd-independent.
    source = Path.expand(opts[:credentials_file] || default_credentials_path())
    force? = !!opts[:force]
    template_name = opts[:seed_template]

    with :ok <- ensure_source_present!(source),
         :ok <- ensure_sandbox_dir!(sandbox_dir),
         {:ok, dest} <- copy_credentials!(source, sandbox_dir, force?),
         :ok <- maybe_seed_template(template_name, sandbox_dir, source) do
      print_summary(name, sandbox_dir, dest, template_name)
      :ok
    end
  end

  # --- defaults -----------------------------------------------------------

  defp default_sandbox_dir(name) do
    Path.join([System.user_home() || System.tmp_dir!(), ".ezagent", "cc-sandboxes", name])
  end

  defp default_credentials_path do
    Path.join(System.user_home() || System.tmp_dir!(), ".claude/.credentials.json")
  end

  # --- guards -------------------------------------------------------------

  defp ensure_source_present!(source) do
    if File.regular?(source) do
      :ok
    else
      Mix.raise("""

      No credentials file at: #{source}

      Reasons this might be empty:

        * You have not run `claude login` yet on this machine.
        * On macOS, `claude login` stores credentials in the system
          Keychain — NOT in `~/.claude/.credentials.json`. In that case
          the sandbox cannot inherit credentials via a file copy. See
          `docs/runbook/cc-agent-e2e.md` for the `api_key_helper`
          workaround (per-template API key).

      Either run `claude login` so the file is created, or pass
      `--credentials-file <path>` pointing at a credentials JSON you
      already have.
      """)
    end
  end

  defp ensure_sandbox_dir!(sandbox_dir) do
    File.mkdir_p!(sandbox_dir)
    File.chmod!(sandbox_dir, 0o700)
    :ok
  end

  # --- copy --------------------------------------------------------------

  defp copy_credentials!(source, sandbox_dir, force?) do
    dest = Path.join(sandbox_dir, ".credentials.json")

    cond do
      File.exists?(dest) and not force? ->
        Mix.raise("""

        Destination already exists: #{dest}

        Pass `--force` to overwrite. (Refusing by default to avoid
        clobbering credentials another agent may already be using.)
        """)

      true ->
        # Read + write (not File.cp!) so we control the destination mode
        # without a race window where the file is world-readable.
        content = File.read!(source)
        # Atomic install: write to a temp file in the same dir, chmod
        # before rename. Same posture as orchestrator_seed's atomic_install.
        tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"

        try do
          File.write!(tmp, content)
          File.chmod!(tmp, 0o600)
          File.rename!(tmp, dest)
        rescue
          e ->
            _ = File.rm(tmp)
            reraise e, __STACKTRACE__
        end

        {:ok, dest}
    end
  end

  # --- optional AgentTemplate seed ----------------------------------------

  # When --seed-template <s> is supplied, dispatch the chat domain's
  # `Ezagent.ActionSet.Template` `:write` to populate the `:template`
  # slice for `template://agent/system/cc-<s>`. Same pattern as
  # `Ezagent.Orchestrator.CcOrchestratorSeed.write_template_slice/2`.
  defp maybe_seed_template(nil, _sandbox_dir, _source), do: :ok

  defp maybe_seed_template(template_name, sandbox_dir, source) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)

    uri = Ezagent.URI.template(:system, :agent, "cc-#{template_name}")

    with {:ok, _pid} <- ensure_template_kind(uri),
         :ok <- write_template_slice(uri, sandbox_dir, template_name, source) do
      :ok
    else
      {:error, reason} ->
        Mix.raise("AgentTemplate seed failed for #{URI.to_string(uri)}: #{inspect(reason)}")
    end
  end

  defp ensure_template_kind(%URI{} = uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _started_or_already, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  defp write_template_slice(%URI{} = uri, sandbox_dir, template_name, source) do
    content = %{
      name: "cc-#{template_name}",
      description:
        "Seeded by `mix ezagent.demo.seed_cc_sandbox` — sandboxed cc agent " <>
          "with pre-copied credentials (avoid re-login flow).",
      flavor: "cc",
      project_cwd: sandbox_dir,
      config_dir: sandbox_dir,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      # §5.B follow-up (c) — the SOURCE `.credentials.json` this E2E agent was
      # seeded FROM (the test-dedicated host login). Persisting it into the
      # template content carries it (via cc `template_data_extra/1`) into the
      # sandbox `respawn_template_data`, so the source agent's credential is
      # refreshed-if-expired on its OWN respawn (the respawn path doesn't
      # re-materialize the config_dir). Production agents log in interactively
      # and never set this.
      credential_source: source,
      default_caps: [],
      created_by: nil,
      created_at: DateTime.utc_now()
    }

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.write")

    admin_uri = Ezagent.Entity.User.admin_uri()

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{content: content},
      # System-principal elimination (#154, 2026-06-19) — operator demo task runs
      # under the real genesis admin entity (`User.admin_uri/0`), NOT the
      # eliminated `system://mix-task` ambient wildcard (shell access = admin
      # authority, in-VM trust §10.5). This is a NON-grant `template.write`
      # dispatch on the AgentTemplate Kind; the INLINE `cap(:any, Template,
      # :write)` scoped to this template instance is the step-5.5 authorizer
      # (`:any` kind axis mirrors the catalog's former `template-materialize`
      # Template cap — `template://` is cross-cutting, Template.workspace_scoped?
      # = false). `granted_by` = `admin_uri` (a real entity per #154, provenance
      # only on an inline authorizer never routed through `Ezagent.Identity.Grant`).
      ctx: %{
        caller: admin_uri,
        caps: [
          %Ezagent.Capability{
            Ezagent.Capability.cap(
              :any,
              Ezagent.ActionSet.Template,
              :write,
              Ezagent.URI.instance(uri),
              :any
            )
            | # `workspace_uri: :any` mirrors the catalog's former
              # `template-materialize` Template cap — `template://` is
              # cross-cutting (Template.workspace_scoped? = false), so the
              # workspace axis is not the scoping dimension; the concrete
              # template `instance` is.
              granted_by: admin_uri,
              granted_at: DateTime.utc_now(),
          }
        ],
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    })
    |> case do
      {:ok, %{content: _}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_write_result, other}}
    end
  end

  # --- summary ------------------------------------------------------------

  defp print_summary(name, sandbox_dir, dest, template_name) do
    template_line =
      case template_name do
        nil ->
          "  (no AgentTemplate seeded — pass --seed-template <name> to also create one)"

        s ->
          "  template URI:    #{Ezagent.URI.template(:system, :agent, "cc-#{s}")}"
      end

    Mix.shell().info("""

    cc sandbox seeded.

      name:            #{name}
      sandbox dir:     #{sandbox_dir}      (chmod 700)
      credentials at:  #{dest}      (chmod 600)
    #{template_line}

    Next step: use this sandbox when spawning a cc agent. Either:

      * In the LV admin form (/admin/agent_templates/new), set the
        AgentTemplate `config_dir = #{sandbox_dir}`.
      * Or set `config_dir` programmatically on the cc.agent
        Template Class data map (the universal, flavor-neutral data key
        is `config_dir` — config_dir promotion, Allen 2026-06-03).

    The spawned `claude` will see CLAUDE_CONFIG_DIR=#{sandbox_dir} and
    use the seeded credentials WITHOUT prompting for re-login.

    macOS caveat: if your host credentials live in Keychain (not in
    #{Path.expand("~/.claude/.credentials.json")}), the file-copy
    approach can't help — see docs/runbook/cc-agent-e2e.md for the
    api_key_helper workaround.
    """)
  end
end
