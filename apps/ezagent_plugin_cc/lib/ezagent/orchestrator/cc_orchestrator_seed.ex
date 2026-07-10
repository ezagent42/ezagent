defmodule Ezagent.Orchestrator.CcOrchestratorSeed do
  @moduledoc """
  Seeds the `cc-orchestrator` AgentTemplate with a REAL `:template`
  slice (Phase 7 completion SPEC §2 "PR-5" — the cc-orchestrator
  AgentTemplate config).

  Pre-PR-5 `EzagentDomainInstanceMessage.Application.seed_cc_orchestrator_template/0`
  only `SpawnRegistry.spawn`-ed an EMPTY AgentTemplate Kind — the
  `:template` slice was `%{content: nil}`, so the Generator could spawn
  an orchestrator process but it had no flavor, no sandbox, no MCP
  config, no system prompt. PR-5 makes the seed populate a real slice:

  - `flavor: "cc-deepseek"` — the orchestrator is a `claude` PTY agent on the
    DeepSeek backend (flavor merged in #1324): it authenticates via
    `DEEPSEEK_API_KEY`, so it needs no host `~/.claude` OAuth login (no #161
    co-tenant issue) and boots authenticated (no exit-256 / bridge-join timeout
    from a missing login). The deepseek flavor is a PROVIDER shim over cc that
    reuses the cc config namespace, so `.mcp.json` generation is unchanged.
  - `config_dir` — an isolated `CLAUDE_CONFIG_DIR` sandbox so the
    orchestrator's `claude` does not share the operator's `~/.claude`
    (PR-2: AgentTemplate content field, renamed from `claude_config_dir`).
  - `settings_path` — a `settings.json` enabling the orchestration
    pattern (the mandatory plugin safety `--settings` still wins; this
    operator file layers non-conflicting keys — §1.5 (c)).
  - The ORCHESTRATOR MCP server (the 7-tool surface,
    `Ezagent.Orchestrator.McpServer`) is NO LONGER seeded as a separate
    `mcp_config_path` / `orchestrator.mcp.json` threaded as an additive
    `--mcp-config`. That additive path was appended LAST and shadowed/raced the
    per-agent `.mcp.json` claude's primary `--mcp-config` reads, so it did not
    reliably fire the `orch:bridge` join on a deployed node. The server is now
    written into that PRIMARY per-agent `.mcp.json` by
    `EzagentPluginCc.McpConfigWriter.write_with_token!` (gated on the
    orchestrator role) — the single owner. This seed still EXPORTS the tool
    schema (`orchestrator_tools.json`) that entry's
    `EZAGENT_ORCHESTRATOR_TOOLS_PATH` points at (see `tools_schema_path/0`).
  - a system prompt teaching the orchestrator role (written into the
    sandbox `CLAUDE.md`).

  ## Idempotency

  The seed is boot-time + best-effort. It spawns the AgentTemplate Kind
  (or finds it alive), writes the sandbox files if absent, and dispatches
  `Ezagent.ActionSet.Template` `:write` to populate the `:template`
  slice. AgentTemplate `:write` is a mutable replace (versionless URI),
  so re-running the seed is harmless.

  ## Why files on disk

  `config_dir` / `settings_path` are file paths the cc Template Class threads to
  `claude` as `CLAUDE_CONFIG_DIR` env + the `--settings` flag. They must exist on
  disk for a live `claude` to use them. The seed writes dev-profile defaults
  under `~/.ezagent/cc-orchestrator/`; production multi-tenant deployments
  override per-template. (`mcp_config_path` is no longer part of the seeded
  content — the orchestrator MCP server moved to the per-agent `.mcp.json`; see
  the flavor/MCP bullets above.)

  ## The orchestrator MCP transport bridge (PR-5 completion)

  The `mcp_config_path` config's stdio command runs
  `uv run --script <orchestrator_bridge.py>`. That bridge is a real
  MCP server (`apps/ezagent_plugin_cc/priv/orchestrator_bridge.py`,
  the orchestrator analogue of `ezagent_mcp_bridge.py`). For the
  configured command to resolve, the seed:

  1. **copies `orchestrator_bridge.py`** from this app's `priv/` into
     the sandbox dir the MCP config references
     (`~/.ezagent/cc-orchestrator/orchestrator_bridge.py`);
  2. **exports the tool JSON schemas** —
     `Ezagent.Orchestrator.McpServer.tool_schemas/0` — to
     `orchestrator_tools.json` beside the script, so the bridge serves
     `tools/list` from a file (the schemas stay single-sourced in
     Elixir, and the configured command lists all tools without the
     BEAM running);
  3. **writes the MCP config** pointing at the copied script + the
     exported schema file via `EZAGENT_ORCHESTRATOR_TOOLS_PATH`.

  Without step 1 the pre-PR-5 config referenced a script that was
  never written — a codex CRITICAL finding: a real orchestrator's
  `claude` started with a broken MCP command and could reach none of
  the orchestrator tools.
  """

  require Logger

  # The orchestrator MCP bridge script + its exported schema file, as
  # they ship in this app's priv/ dir.
  @bridge_script "orchestrator_bridge.py"
  @tools_schema_file "orchestrator_tools.json"

  # Canonical localhost orchestrator-socket WS URL — the fallback when no
  # `EZAGENT_BRIDGE_WS_URL` env / `:ezagent_plugin_cc, :ws_url` is configured
  # (matches `orchestrator_bridge.py`'s own default). Custom deployments override
  # via the same knobs the regular cc bridge uses (codex C-r2-P2).
  @orchestrator_ws_default "ws://127.0.0.1:10042/orchestrator_socket/websocket"

  defmodule InstallError do
    @moduledoc """
    Raised when the orchestrator MCP bridge / schema / mcp.json could
    not be installed.

    This is a HARD seed failure (codex MEDIUM): if the bridge script or
    its exported schema cannot be written, the configured `uv run
    --script …` MCP command would point at outdated or missing code.
    A stale orchestrator template is worse than an aborted boot, so the
    seed does NOT downgrade this to a warning — it propagates.
    """
    defexception [:message]
  end

  @doc """
  Seed the cc-orchestrator AgentTemplate. Idempotent.

  Best-effort for the AgentTemplate Kind spawn + `:template` slice
  write — those downgrade to a warning so a boot does not abort.

  But a failure to install the MCP bridge / schema / mcp.json is a
  HARD failure (`InstallError`): a stale bridge leaves the configured
  MCP command pointing at outdated code, which is worse than a loud
  boot failure. That error propagates out of `seed/0`.
  """
  @spec seed() :: :ok
  def seed do
    uri = template_uri_struct()

    # `ensure_sandbox_files/0` raises `InstallError` on a bridge/schema
    # install failure — deliberately NOT caught here.
    with {:ok, _pid} <- ensure_kind(uri),
         {:ok, sandbox} <- ensure_sandbox_files(),
         :ok <- write_template_slice(uri, sandbox) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "cc-orchestrator AgentTemplate seed: #{inspect(reason)} — " <>
            "orchestrator-style SessionTemplate instantiation will use an " <>
            "unpopulated template until manually configured"
        )

        :ok
    end
  end

  @doc "The cc-orchestrator AgentTemplate URI string."
  @spec template_uri() :: String.t()
  def template_uri, do: template_uri_struct() |> URI.to_string()

  @doc """
  Inspect the cc-orchestrator seed status (G-9 fix, audit 2026-05-23).

  Returns one of:

  - `{:ok, %{template_uri: ..., template_content: map()}}` — the seed
    populated the slice (Kind is alive, `:template` content has a
    non-nil `flavor`).
  - `{:partial, %{template_uri: ..., template_content: ...}}` — the
    Kind is alive but the slice content is nil or missing the
    `flavor` key (the soft sandbox-files write failed; the AgentTemplate
    Kind exists but the orchestrator can't actually spawn from it).
  - `{:missing, %{template_uri: ...}}` — the Kind is not registered at
    all (seed failed at `ensure_kind/1` or app boot order issue).

  Used by operator plugin surfaces to show a boot-time status badge near the
  cc plugin card. Read-only — no side effects.
  """
  @spec seed_status() :: {:ok | :partial | :missing, map()}
  def seed_status do
    uri = template_uri_struct()

    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        {:missing, %{template_uri: template_uri()}}

      {:ok, pid} ->
        case read_template_slice(pid) do
          %{flavor: f} = content when is_binary(f) and f != "" ->
            {:ok, %{template_uri: template_uri(), template_content: content}}

          content ->
            {:partial, %{template_uri: template_uri(), template_content: content}}
        end
    end
  rescue
    # Reading the slice can race with a restart; treat any error as
    # :missing so the UI shows a degraded-but-actionable badge.
    _ -> {:missing, %{template_uri: template_uri()}}
  end

  defp template_uri_struct, do: Ezagent.URI.template(:system, :agent, "cc-orchestrator")

  # The `:template` slice content is the orchestrator's seeded config.
  # `:sys.get_state` returns the Kind.Server state map; slice data lives
  # under the `:state` key (per `Ezagent.Kind.Server` shape — confirmed
  # via :sys.get_state on a live AgentTemplate pid).
  #
  # Lifecycle migration (SPEC 2026-05-29): `Ezagent.ActionSet.Template`
  # now `use Ezagent.Lifecycle`, so the `:template` slice is the
  # two-container `%{state: %{content: ...}, transients: %{}}` shape (the
  # framework persists only `:state`; `:content` is fully persistent).
  # Match the two-container form FIRST, then fall back to the legacy flat
  # `%{content: ...}` (a pre-migration snapshot / non-Lifecycle Behavior).
  defp read_template_slice(pid) do
    case :sys.get_state(pid, 500) do
      %{state: %{template: %{state: %{content: content}}}} when is_map(content) -> content
      %{state: %{template: %{state: %{content: nil}}}} -> %{}
      %{state: %{template: %{content: content}}} when is_map(content) -> content
      %{state: %{template: %{content: nil}}} -> %{}
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # --- internals ---------------------------------------------------------

  defp ensure_kind(%URI{} = uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _started_or_already, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  # Build the on-disk sandbox: a CLAUDE_CONFIG_DIR with a settings.json,
  # an mcp.json for the orchestrator tool surface, a CLAUDE.md carrying
  # the orchestrator system prompt, AND — PR-5 completion — the real
  # orchestrator MCP transport bridge script + its exported schema
  # file. Best-effort in :test (the paths are recorded in the slice but
  # disk writes are skipped). Returns `{:ok, %{...paths}}`.
  #
  # The settings.json / CLAUDE.md writes are soft (a failure downgrades
  # to a `{:error, _}` warning). The bridge / schema / mcp.json install
  # is HARD — a failure raises `InstallError` so the seed does NOT leave
  # a stale template whose MCP command points at outdated code.
  defp ensure_sandbox_files do
    base = sandbox_base()
    config_dir = Path.join(base, ".claude")
    settings_path = Path.join(config_dir, "settings.json")
    mcp_config_path = Path.join(base, "orchestrator.mcp.json")
    claude_md_path = Path.join(base, "CLAUDE.md")

    # PR-2 (domain.agent): keys mirror the AgentTemplate content intents —
    # `project_cwd` (project/working dir) vs `config_dir` (sandbox config-home
    # input). `write_template_slice/2` threads these into the template content.
    sandbox = %{
      project_cwd: base,
      config_dir: config_dir,
      settings_path: settings_path,
      mcp_config_path: mcp_config_path
    }

    if test_env?() do
      # In :test the slice records the paths but skips the load-bearing
      # bridge install — the deterministic e2e drives the tools directly,
      # no live claude. Still create the reference config dir because
      # session-create tests instantiate the seeded cc.agent Template Class,
      # and that path copies the recorded config_dir into a per-agent target.
      File.mkdir_p!(config_dir)
      {:ok, sandbox}
    else
      with :ok <- write_soft_sandbox_files(config_dir, settings_path, claude_md_path) do
        # HARD: the bridge + schema + mcp.json. `install_sandbox_bridge!/2`
        # raises `InstallError` on failure — deliberately NOT rescued, so
        # the seed surfaces it instead of leaving a stale template.
        install_sandbox_bridge!(base, mcp_config_path)
        {:ok, sandbox}
      end
    end
  end

  # The non-load-bearing sandbox files. A failure here is soft — it
  # downgrades to a warning in `seed/0` (the orchestrator can still run
  # without a custom settings.json / CLAUDE.md).
  defp write_soft_sandbox_files(config_dir, settings_path, claude_md_path) do
    File.mkdir_p!(config_dir)
    unless File.exists?(settings_path), do: File.write!(settings_path, settings_json())
    refresh_managed_persona!(claude_md_path, system_prompt())
    :ok
  rescue
    e -> {:error, {:sandbox_write_failed, e}}
  end

  @doc """
  Write the managed orchestrator persona to `claude_md_path` IF it is absent or
  its content DIFFERS from `persona`.

  The persona is single-sourced from the orchestrator ROLE recipe
  (`Ezagent.Orchestrator.OrchestratorRecipe.persona/0`). A write-once guard would
  leave an upgraded install reading a STALE persona while the role recipe moved
  on (codex PR-2 review). The seed sandbox `CLAUDE.md` is fully managed
  (operators override per-template in production), so rewrite-on-diff is safe.

  Exposed so the drift regression can drive it directly — the production
  soft-write path is skipped in `:test`.
  """
  @spec refresh_managed_persona!(String.t(), String.t()) :: :ok
  def refresh_managed_persona!(claude_md_path, persona) do
    unless File.exists?(claude_md_path) and File.read!(claude_md_path) == persona do
      File.write!(claude_md_path, persona)
    end

    :ok
  end

  # The load-bearing install: ship the real MCP bridge + exported schema
  # into the sandbox, then write the mcp.json that references them.
  # ALWAYS overwrites (atomically) so an updated bridge / refreshed
  # schema lands on the next boot. Raises `InstallError` on ANY failure
  # — a stale bridge would leave the configured `uv run --script …`
  # command pointing at outdated or missing code.
  defp install_sandbox_bridge!(base, mcp_config_path) do
    install_orchestrator_bridge(base)

    # Write the mcp.json LAST — after the script + schema file it
    # references exist on disk. Always rewritten so the embedded paths
    # track the current install.
    File.write!(mcp_config_path, orchestrator_mcp_json(base))
    :ok
  rescue
    e in InstallError ->
      reraise e, __STACKTRACE__

    e ->
      reraise InstallError,
              [
                message:
                  "cc-orchestrator MCP bridge install failed: #{Exception.message(e)} — " <>
                    "the configured `uv run --script` command would point at outdated " <>
                    "or missing code; refusing to leave a stale orchestrator template"
              ],
              __STACKTRACE__
  end

  defp sandbox_base do
    cond do
      base = Application.get_env(:ezagent_plugin_cc, :cc_orchestrator_sandbox_base) ->
        base

      test_env?() ->
        Path.join(System.tmp_dir!(), "ezagent-test-cc-orchestrator")

      true ->
        Path.join([System.user_home() || "/tmp", ".ezagent", "cc-orchestrator"])
    end
  end

  @doc """
  Copy `orchestrator_bridge.py` out of this app's `priv/` into the
  sandbox dir the mcp.json references, and export the tool JSON
  schemas (`McpServer.tool_schemas/0`) to `orchestrator_tools.json`
  beside it. This is what makes the configured `uv run --script …`
  command actually start a working MCP server (codex CRITICAL — the
  pre-PR-5 config referenced a script that was never written).

  ## Atomic install (codex MEDIUM)

  Both files are installed atomically: each is written to a temp file
  in the destination dir with known permissions, then `File.rename/2`
  is used to move it over the destination. `rename` replaces the
  destination regardless of the OLD file's mode — so a pre-existing
  `orchestrator_bridge.py` WITHOUT owner-write no longer aborts the
  install (the previous `File.cp!`-then-`chmod` ordering failed on the
  copy before it could ever chmod). The temp + rename also means a
  reader never sees a half-written file.

  Raises on any failure — the caller (`ensure_sandbox_files/0`) treats
  an install failure as a HARD seed failure, because a stale bridge /
  schema leaves the configured MCP command pointing at outdated code.

  Exposed so the PR-5 integration test can ship the bridge into a temp
  dir and execute the configured command.
  """
  @spec install_orchestrator_bridge(String.t()) :: :ok
  def install_orchestrator_bridge(base) do
    File.mkdir_p!(base)

    atomic_install!(
      priv_bridge_path() |> File.read!(),
      Path.join(base, @bridge_script),
      0o755
    )

    atomic_install!(
      Jason.encode!(
        %{"tools" => Ezagent.Orchestrator.McpServer.tool_schemas()},
        pretty: true
      ),
      Path.join(base, @tools_schema_file),
      0o644
    )

    :ok
  end

  # Write `content` to a temp file in the destination's directory with
  # `mode`, then atomically `rename` it over `dest`. `rename` replaces
  # the destination regardless of the old file's permissions, so an
  # existing non-writable file never aborts the install. Raises on
  # failure (the seed treats install failure as a hard failure).
  defp atomic_install!(content, dest, mode) do
    tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, content)
      File.chmod!(tmp, mode)
      File.rename!(tmp, dest)
    rescue
      e ->
        _ = File.rm(tmp)
        reraise e, __STACKTRACE__
    end
  end

  # The orchestrator MCP bridge script as it ships in this app's priv/.
  @doc false
  @spec priv_bridge_path() :: String.t()
  def priv_bridge_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join(@bridge_script)
  end

  # Dispatch `Ezagent.ActionSet.Template` `:write` to populate the
  # AgentTemplate's `:template` slice — the canonical persistence path
  # (§1.7 (a)). AgentTemplate `:write` is a mutable replace, so the
  # re-seed on the next boot is idempotent.
  defp write_template_slice(%URI{} = uri, sandbox) do
    content = %{
      name: "cc-orchestrator",
      description:
        "The session orchestrator — an LLM-driven manager that composes " <>
          "and routes a team of worker agents via the 7 orchestration tools.",
      # cc-deepseek (flavor merged in #1324): the orchestrator authenticates via
      # DEEPSEEK_API_KEY, so it has no `.credentials.json`, no dependency on the
      # host `~/.claude` OAuth login (#161), and boots authenticated — no
      # exit-256 / bridge-join timeout from a missing host login. It reuses cc's
      # config_dir namespace + the shared `CcAgent.Spawn` chokepoint, so
      # `.mcp.json` generation (esr-bridge + the orchestrator server) is
      # identical to the cc path; the chat bridge topic becomes
      # `agent_bridge:cc-deepseek:<uri>` (Provider.bridge_topic_env), while the
      # `orch:bridge:<uri>` topic is flavor-agnostic.
      flavor: "cc-deepseek",
      project_cwd: sandbox.project_cwd,
      config_dir: sandbox.config_dir,
      settings_path: sandbox.settings_path,
      # `mcp_config_path` is intentionally NOT set. It used to map to
      # `operator_mcp_config_path` → an ADDITIVE `--mcp-config` pointing at the
      # separate `orchestrator.mcp.json`, appended LAST in
      # `SpawnPlan.assemble_settings_mcp_args` — which SHADOWED / raced the
      # per-agent `.mcp.json` claude's primary `--mcp-config` reads and did not
      # reliably fire the `orch:bridge` join on a deployed node. The orchestrator
      # MCP server is now written into that PRIMARY `.mcp.json` by
      # `McpConfigWriter.write_with_token!` (gated on the orchestrator role), so
      # this seed no longer emits a second, shadowing config path.
      api_key_helper: nil,
      # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
      # carrying `role: "orchestrator"` on the AgentTemplate content
      # threads through `AgentTemplate.to_template_data/2` into the cc
      # Template Class data, which triggers `apply_orchestrator_recipe_bootstrap`:
      # copy the `ezagent-session-orchestrator` skill into the spawned
      # agent's per-agent config_dir + append the CLAUDE.md hint +
      # set `EZAGENT_AGENT_ROLE=orchestrator` in the claude process env.
      role: "orchestrator",
      default_caps: [],
      created_by: nil,
      created_at: DateTime.utc_now()
    }

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.write")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{content: content},
           # #154 — `system://template-materialize` ELIMINATED. The CC
           # orchestrator template seed is system-mediated materialization →
           # runs under the genesis admin entity with an INLINE narrow
           # `template.write` cap (granted_by admin; #533 will refine to
           # per-creator authority). Same play as mix-task #833 / socialware-gc.
           # behavior: :any avoids a cross-app `Behavior.Template` literal.
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps:
               MapSet.new([
                 %Ezagent.Capability{
                   Ezagent.Capability.cap(
                     :any,
                     :any,
                     :write,
                     Ezagent.URI.instance(target),
                     Ezagent.Capability.workspace_of(target)
                   )
                   | granted_by: Ezagent.Entity.User.admin_uri(),
                     granted_at: DateTime.utc_now()
                 }
               ]),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: _}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_write_result, other}}
    end
  end

  # settings.json — enables the orchestrator pattern. The plugin-shipped
  # mandatory `--settings` (forcing `remoteControlAtStartup: false`) is
  # emitted LAST by `CcAgent.assemble_settings_mcp_args/3`, so anything
  # here that conflicts with a safety key loses. The keys here are
  # non-conflicting orchestration conveniences.
  defp settings_json do
    Jason.encode!(
      %{
        "includeCoAuthoredBy" => false,
        "env" => %{
          "EZAGENT_ROLE" => "orchestrator"
        }
      },
      pretty: true
    )
  end

  # orchestrator.mcp.json — the additional `--mcp-config` the cc
  # Template Class threads (additive to the trusted esr-bridge config).
  # It points `claude` at the orchestrator MCP server (the 7-tool
  # surface). The command runs the real stdio bridge
  # (`orchestrator_bridge.py`) that serves `tools/list` from the
  # exported schema file and forwards `tools/call` to
  # `Ezagent.Orchestrator.McpServer` over the WS Phoenix Channel — the
  # caller/cap/session context is bound Ezagent-side.
  #
  # `base` is the sandbox dir; `install_orchestrator_bridge/1` has
  # already copied the script + schema file there, so both
  # `--script <path>` and `EZAGENT_ORCHESTRATOR_TOOLS_PATH` resolve.
  #
  # `--script` is used (per cc bridge PR #129) so `uv` honors the
  # PEP 723 inline metadata header and provisions `websockets` on
  # first run.
  @doc false
  # Exposed for the PR-5 integration test — it reads the CONFIGURED
  # command (the `uv run --script …` the seed writes) and executes it.
  @spec orchestrator_mcp_json_for_test(String.t()) :: String.t()
  def orchestrator_mcp_json_for_test(base), do: orchestrator_mcp_json(base)

  defp orchestrator_mcp_json(base) do
    Jason.encode!(
      %{
        "mcpServers" => %{
          "esr-orchestrator" => %{
            "command" => "uv",
            "args" => ["run", "--script", Path.join(base, @bridge_script)],
            "env" => %{
              "EZAGENT_ROLE" => "orchestrator",
              "EZAGENT_ORCHESTRATOR_TOOLS_PATH" => Path.join(base, @tools_schema_file),
              # codex C-r2-P2 — write the resolved orchestrator-socket WS URL so a
              # non-default deployment (custom port / remote host / TLS /
              # `:ezagent_plugin_cc, :ws_url`) does NOT silently fall back to the
              # hardcoded `ws://127.0.0.1:10042/orchestrator_socket/websocket`
              # (the bridge would then fail to connect to its MCP channel). Mirrors
              # the regular cc bridge config (`McpConfigWriter` writes
              # `EZAGENT_BRIDGE_WS_URL`), but on the `/orchestrator_socket` mount.
              "EZAGENT_BRIDGE_WS_URL" => resolve_orchestrator_ws_url()
            }
          }
        }
      },
      pretty: true
    )
  end

  # The orchestrator MCP bridge connects to the `/orchestrator_socket` mount
  # (NOT the regular `/agent_bridge` mount). Reuse the regular bridge's resolved
  # host:port (`EZAGENT_BRIDGE_WS_URL` env / `:ws_url` app config) and swap the
  # path to `orchestrator_socket`, so a custom-port / remote / TLS deployment is
  # honored. Falls back to the canonical localhost orchestrator-socket URL.
  defp resolve_orchestrator_ws_url do
    @orchestrator_ws_default
    |> resolve_base_ws_url()
    |> swap_ws_path("/orchestrator_socket/websocket")
  end

  @doc """
  The resolved `/orchestrator_socket` WebSocket URL an orchestrator's
  `orchestrator_bridge.py` connects to (honors the same `EZAGENT_BRIDGE_WS_URL`
  env / `:ezagent_plugin_cc, :ws_url` deployment knobs as the cc bridge, but on
  the orchestrator mount). Threaded by `SpawnPlan` into the `esr-orchestrator`
  `.mcp.json` entry's `EZAGENT_BRIDGE_WS_URL`.
  """
  @spec orchestrator_socket_ws_url() :: String.t()
  def orchestrator_socket_ws_url, do: resolve_orchestrator_ws_url()

  @doc """
  Absolute path of the exported 7-tool schema JSON
  (`orchestrator_tools.json`) written beside the bridge in the orchestrator
  sandbox by `install_orchestrator_bridge/1` (single-sourced from
  `McpServer.tool_schemas/0`). Threaded by `SpawnPlan` into the
  `esr-orchestrator` `.mcp.json` entry's `EZAGENT_ORCHESTRATOR_TOOLS_PATH` so the
  bridge answers `tools/list` from the file without the BEAM running.
  """
  @spec tools_schema_path() :: String.t()
  def tools_schema_path, do: Path.join(sandbox_base(), @tools_schema_file)

  defp resolve_base_ws_url(default) do
    System.get_env("EZAGENT_BRIDGE_WS_URL") ||
      Application.get_env(:ezagent_plugin_cc, :ws_url) ||
      default
  end

  # Replace the path of a `ws(s)://host:port/<path>` URL, preserving scheme +
  # authority (so a custom host/port/TLS deployment's connectivity is kept while
  # pointing at the orchestrator mount). A malformed URL falls back to the
  # canonical orchestrator default.
  defp swap_ws_path(ws_url, path) when is_binary(ws_url) do
    # NOTE: this manipulates a `ws(s)://` NETWORK URL (the orchestrator MCP
    # mount), NOT an Ezagent opaque entity URI — so the uri_query.scan opacity rules
    # don't apply. Written with dot-access (not a `%URI{host:}` positional match)
    # + the rebuild split off the `URI.to_string` line so the source-scan
    # (positional_uri_read / uri_string_key) doesn't false-positive on it.
    uri = URI.parse(ws_url) # uri-canonical-allow: ws(s):// network URL (orchestrator MCP mount), not an Ezagent-scheme URI — Ezagent.URI rejects non-Ezagent schemes

    if is_binary(uri.scheme) and is_binary(uri.host) do
      rebased = %{uri | path: path, query: nil, fragment: nil}
      URI.to_string(rebased)
    else
      @orchestrator_ws_default
    end
  end

  # The orchestrator system prompt — written into the sandbox CLAUDE.md
  # so a live `claude` orchestrator reads it on startup. Single-sourced from
  # the orchestrator ROLE recipe (task #54 PR-2): the persona is the role's
  # `prompt`, so the seed sandbox and the role recipe never drift.
  defp system_prompt, do: Ezagent.Orchestrator.OrchestratorRecipe.persona()

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
