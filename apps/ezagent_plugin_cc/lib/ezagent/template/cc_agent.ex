defmodule Ezagent.PluginCc.Template.CcAgent do
  @moduledoc """
  Unified CC agent Template Class (PR-D2, Allen 2026-05-19; mode field
  removed PR-V1-fix Allen 2026-05-21).

  Replaces the previous split between `cc.pty` and `cc.channel_instance`
  Template Classes. The operator now adds ONE template (`cc.agent`)
  per CC agent and the spawn path is always local-pty.

  The earlier PR-D2 plan reserved a `mode` field with values
  `"local-pty"` / `"remote-channel"` so a future external-bridge mode
  could share the same Template Class. Allen 2026-05-21 cut this:
  remote-channel was never wired and the placeholder + dichotomy were
  dead weight. If/when remote support returns, it will land as a
  separate plugin + Template Class, not a mode field. The `"mode"`
  field is no longer part of the schema; if a legacy row still carries
  it the template is accepted and the field ignored (no migration
  required — see PR-D2 migration that originally seeded the field).

  ## Architecture: instantiate PRODUCES the Kind (Allen 2026-05-21)

  Allen's mental model is "Template.instantiate produces a new Kind".
  Pre-V1-fix the AgentNewLive flow inverted this: it called
  `SpawnRegistry.spawn(agent_uri)` directly (which spawned the Agent
  Kind) BEFORE `Workspace.add_template/3` (which chains to
  instantiate). cc.agent.instantiate then short-circuited on the
  already-alive Kind and started PtyServer only — making it look like
  templates couldn't bring an Agent Kind up standalone.

  The V1 fix removed the pre-spawn from AgentNewLive AND made this
  template do the full job: when instantiate runs it BOTH ensures the
  Agent Kind exists (via `SpawnRegistry.spawn/1`) AND starts the
  PtyServer. After `add_template → invoke_template → instantiate`
  returns, the caller has a fully-operational cc agent.

  ## Template data

  Legacy 3-key form (still valid — backward compat):

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path"
      }

  Extended 7-key form (Phase 7 completion PR-1, SPEC §1.5 (c)) — the
  AgentTemplate→cc adapter (`Ezagent.Entity.AgentTemplate.to_template_data/2`)
  threads these four OPTIONAL sandbox keys:

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path",
        "operator_settings_path" => "/path/to/operator/settings.json",
        "operator_mcp_config_path" => "/path/to/operator/mcp.json",
        "claude_config_dir" => "/path/to/sandbox/.claude",
        "api_key_helper" => "/path/to/api-key-helper.sh"
      }

  All four extended keys are optional — absent ⇒ the legacy behavior,
  no regression. `build_claude_cmd/3` emits the operator `--settings` /
  `--mcp-config` such that the **mandatory plugin safety `--settings`
  is LAST** (claude `--settings` is last-wins, so `remoteControlAtStartup:
  false` is non-bypassable) and the trusted esr-bridge `--mcp-config` is
  never replaced (claude merges MCP configs additively — an operator
  config adds servers but cannot delete the bridge).

  ## codex HIGH-2 — argv-safe invocation

  `build_claude_cmd/3` returns an **argv list** (`[cmd | args]`), not a
  shell string. `Ezagent.Domain.Pty` runs a list-form `cmd_override`
  via `execve` with NO shell, so every operator-controlled sandbox
  path is exactly ONE `argv[]` element. An operator value containing
  a space, a literal ` --settings /tmp/x.json`, or shell
  metacharacters (`;`, `$()`, backtick, `&&`) is delivered to `claude`
  verbatim as a single argument — it cannot create an extra flag
  (which would defeat the `--settings` last-wins safety guarantee) and
  it cannot execute a shell command. `claude_config_dir` is passed as
  a structured `CLAUDE_CONFIG_DIR` env var via the Server's `:cmd_env`
  param, never as a `VAR=val` command prefix.

  ## codex review of #233 — argv element 0 is an ABSOLUTE PATH

  The no-shell argv form has a corollary the PR-1 hardening missed:
  erlexec's list-form `:exec.run/2` runs `execve(3)` directly — no
  shell, hence no `$PATH` search. A bare `"claude"` as argv element 0
  resolves only if `claude` lives in `cwd`, so the hardening regressed
  production cc startup (the pre-#233 shell-string path did resolve
  `claude` via `$PATH`). `build_claude_cmd/3` now resolves the
  `claude` executable to an absolute path via
  `System.find_executable/1` before building the argv. When `claude`
  is not on `PATH`, `build_claude_cmd/3` returns
  `{:error, :claude_not_found}` — a clear, propagated error, NOT a
  silent fall back to the shell. `instantiate/3` therefore fails
  loudly instead of spawning a PtyServer whose child can never start.

  ## Idempotency (PR-D2 + V1 fix)

  `instantiate/3` first looks up `agent_uri` in `KindRegistry`.
  If alive, returns the existing URI — no respawn, no PTY waste.
  Otherwise spawns the Agent Kind via `SpawnRegistry.spawn_detailed/1`
  then starts the PtyServer via `Ezagent.Domain.Pty.start/2` (facade
  over the `ezagent_domain_pty` Tier-2 app). Both layers are atomically
  dedup'd: Agent Kind via `KindRegistry` (entity:// spawn fn returns
  `{:error, {:already_started, _}}` for duplicates), PtyServer via the
  Domain.Pty :via Registry (`EzagentDomainPty.Registry`).

  ## codex round-6 HIGH-1 — the `fresh?` signal

  `instantiate/3` returns the 3-element `{:ok, [agent_uri],
  %{fresh?: boolean()}}` form. `fresh?` is `true` iff THIS call's
  `DynamicSupervisor.start_child` STARTED the Agent Kind worker — the
  atomic outcome `SpawnRegistry.spawn_detailed/1` preserves. The
  idempotency short-circuit (Kind + PtyServer already alive) returns
  `fresh?: false` — the worker pre-existed.

  `update_agent_template`'s rollback-safe swap reads `fresh?` to refuse
  silently adopting a worker another process created. Deriving it from
  the atomic spawn result — rather than a pre-probe of `KindRegistry`
  before the spawn — removes a TOCTOU window: a concurrent registration
  between a pre-probe and the spawn would make an adopted worker read
  as fresh.

  ## codex round-8 HIGH-1 — a `fresh?: false` result starts NO sidecar

  Round 6/7 made `fresh?` an atomic, side-effect-aware signal at the
  ESR domain layer. But the Template Class itself was still not
  side-effect-free for a rejected adoption: `spawn_for_local_pty/2`
  called `ensure_agent_kind/1` and then UNCONDITIONALLY continued to
  `ensure_pty_server/3`. When `ensure_agent_kind/1` finds the Agent
  Kind `:already_started` — a worker THIS call did NOT create —
  `ensure_pty_server/3` would still start a PTY / `claude` sidecar for
  that pre-existing (possibly foreign or orphaned) worker, attaching a
  new process + config + cwd to it.

  Round 8 makes the fresh-check happen BEFORE any stateful side effect.
  When `ensure_agent_kind/1` reports `:already_started`,
  `spawn_for_local_pty/2` returns `{:ok, [agent_uri], %{fresh?: false}}`
  IMMEDIATELY — it does NOT call `ensure_pty_server/3`, does NOT start
  a sidecar. Whether to adopt a worker this call did not create is the
  caller's (the Generator's / `update_agent_template`'s) decision, not
  the Template Class's. The Template Class only ever brings up a PTY
  for a worker IT freshly started.

  ## codex round-10 HIGH-2 — the Template Class undoes its OWN partial spawn

  Round 8 stopped a `:already_started` Kind from getting a sidecar, but
  the FRESH path was still not all-or-nothing: `spawn_for_local_pty/2`
  freshly STARTED the Agent Kind, then called `ensure_pty_server/3` —
  and a PTY / `claude` startup failure there returned a bare
  `{:error, reason}` while the just-started Agent Kind stayed LIVE. As a
  Generator agent slot that is an orphan: the slot returns
  `{:error, _}` with NO worker URI, so the Generator's `cleanup_partial/1`
  cannot terminate it (it never learns the URI). The orphan then blocks
  future retries via the candidate-URI preflight.

  Round 10 makes the spawner own its own partial-spawn teardown: when
  this call FRESHLY started the Agent Kind and a LATER step
  (`ensure_pty_server/3`) fails, `spawn_for_local_pty/2` terminates the
  Agent Kind it itself started (`Ezagent.Kind.terminate/1`) BEFORE
  returning the error. The function now either fully succeeds or leaves
  ZERO residue. An `:already_started` Kind is never terminated — this
  call did not create it. Only the Kind PROCESS is terminated; lineage
  and workspace binding are ESR-domain registries the plugin must not
  touch (3-tier) — and `spawn_from_template_content/4` had not recorded
  either (it gates them on a `fresh?: true` success this path never
  returns).

  ## Domain.Pty PR-A (2026-05-21 SPEC v1)

  The cc-specific claude invocation (mcp.json generation, settings
  override path, `--dangerously-load-development-channels`,
  `--permission-mode bypassPermissions`) used to live inside
  `Ezagent.PluginCc.PtyServer.spawn_claude_directly/1` (historical).
  It now lives here (`build_claude_cmd/3`) because Domain.Pty.Server
  is Tier-2 and cannot reference cc-plugin modules like
  `EzagentPluginCc.McpConfigWriter`.
  The invocation is supplied as `cmd_override` on the Server init args
  — an argv LIST (codex HIGH-2), which Server runs under erlexec's PTY
  via `execve` with no shell.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "cc.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_sandbox_keys(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  # Phase 7 completion PR-1 (SPEC §1.5 (c)) — the four sandbox keys are
  # OPTIONAL. Absent ⇒ legacy behavior (the 3-key form still validates).
  # When present, each must be a non-empty string.
  @optional_sandbox_keys ~w(operator_settings_path operator_mcp_config_path
                            claude_config_dir api_key_helper)

  defp check_optional_sandbox_keys(tmpl) do
    Enum.reduce_while(@optional_sandbox_keys, :ok, fn key, :ok ->
      case Map.fetch(tmpl, key) do
        :error -> {:cont, :ok}
        {:ok, v} when is_binary(v) and v != "" -> {:cont, :ok}
        {:ok, bad} -> {:halt, {:error, {:invalid_sandbox_key, key, bad}}}
      end
    end)
  end

  defp check_class(%{"class" => "cc.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment:
        # /<workspace>/<entity_name>. Flavor lives in the entity_name
        # prefix as `<flavor>_<rest>` (SPEC v2 §5.14). cc.agent
        # template requires flavor=cc.
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "cc" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "cc"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/cc_<name>` (Phase 9 PR-2)"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/cc_<name>` (Phase 9 PR-2)"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, _workspace_uri) do
    agent_uri = URI.parse(uri_str)

    # PR-D2 idempotency short-circuit: if BOTH the Agent Kind and the
    # PtyServer are already alive we have nothing to do. Each plugin
    # re-running Workspace.Loader.load_all/0 hits this on subsequent
    # passes; the first pass spawns, the rest no-op.
    #
    # codex round-6 HIGH-1 — the 3-element `{:ok, uris, %{fresh?: _}}`
    # return carries whether THIS call STARTED the Agent Kind worker.
    # The short-circuit means the worker pre-existed → `fresh?: false`.
    cond do
      agent_kind_alive?(agent_uri) and pty_server_alive?(agent_uri) ->
        {:ok, [agent_uri], %{fresh?: false}}

      true ->
        spawn_for_local_pty(agent_uri, tmpl)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # V1 fix Allen 2026-05-21: template instantiate PRODUCES the Kind.
  # Before this fix, instantiate started only PtyServer and assumed
  # someone else (AgentNewLive's direct SpawnRegistry.spawn call) had
  # already created the Agent Kind. The new flow:
  #
  # 1. Ensure the Agent Kind exists (via SpawnRegistry — routed by
  #    chat plugin's "entity" spawn fn to AgentSupervisor).
  # 2. Start the PtyServer for this agent_uri.
  #
  # Both steps are idempotent: SpawnRegistry returns
  # `{:error, {:already_started, _}}` for an existing Agent Kind, and
  # the PtyServer's :via Registry collapses concurrent starts.
  defp spawn_for_local_pty(agent_uri, tmpl) do
    cwd = Map.fetch!(tmpl, "cwd")

    # codex round-6 HIGH-1 — `ensure_agent_kind/1` reports whether THIS
    # call STARTED the Agent Kind worker (`:started`) or adopted a
    # pre-existing one (`:already_started`). The worker IS the Agent
    # Kind; the PtyServer is a sidecar — so the worker's freshness is
    # the Agent Kind's freshness. Threaded out as `%{fresh?: _}`.
    #
    # codex round-8 HIGH-1 — the fresh-check gates the PTY sidecar.
    # When the Agent Kind was `:already_started` (a worker this call
    # did NOT create), return `fresh?: false` IMMEDIATELY without
    # calling `ensure_pty_server/3`. Starting a PTY / `claude` sidecar
    # for a pre-existing (possibly foreign or orphaned) worker would
    # make a rejected adoption non-zero-side-effect. The Template Class
    # only brings up a sidecar for a worker IT freshly started; whether
    # to adopt a pre-existing worker is the caller's decision.
    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
      case started_or_adopted do
        :already_started ->
          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          # codex round-10 HIGH-2 — the Template Class owns its OWN
          # partial-spawn teardown. `ensure_agent_kind/1` FRESHLY
          # started the Agent Kind on this call; if `ensure_pty_server/3`
          # (PTY / `claude` startup) now fails, the just-started Agent
          # Kind would leak — a live orphan the Generator's
          # `cleanup_partial/1` cannot see (the slot returned a bare
          # `{:error, _}` with no worker URI). So if a step AFTER the
          # fresh Kind start fails, the Template Class terminates the
          # Kind it itself started BEFORE returning the error. The
          # function then either fully succeeds or leaves ZERO residue.
          # (An `:already_started` Kind is NEVER terminated here — this
          # call did not create it; that branch already returned early
          # above with `fresh?: false`.) The Template Class terminates
          # only the Kind PROCESS — lineage / workspace binding are
          # ESR-domain registries the plugin must not touch (3-tier);
          # `spawn_from_template_content/4` had not recorded either yet
          # (it gates them on the `{:ok, ..., fresh?: true}` it never
          # received).
          case ensure_pty_server(agent_uri, cwd, tmpl) do
            :ok ->
              {:ok, [agent_uri], %{fresh?: true}}

            {:error, reason} ->
              _ = Ezagent.Kind.terminate(agent_uri)
              {:error, reason}
          end
      end
    end
  end

  # codex round-6 HIGH-1 — `SpawnRegistry.spawn_detailed/1` preserves
  # the atomic `DynamicSupervisor` outcome: exactly one concurrent
  # caller gets `:started`, every other gets `:already_started`. This
  # is the ground-truth freshness signal — NOT a pre-probe (a pre-probe
  # is a TOCTOU window). Returns `{:ok, :started | :already_started}`.
  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} ->
        {:ok, :started}

      {:ok, :already_started, _pid} ->
        # Atomic dedup at KindRegistry / supervisor level — the Kind was
        # spawned by a concurrent caller (or by an earlier instantiate
        # that crashed between Kind spawn and PtyServer start). Still a
        # success, but THIS call did not create the worker.
        {:ok, :already_started}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: SpawnRegistry.spawn_detailed failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:agent_kind_spawn_failed, reason}}
    end
  end

  defp ensure_pty_server(agent_uri, cwd, tmpl) do
    # Domain.Pty PR-A: route through the facade instead of
    # DynamicSupervisor.start_child on EzagentPluginCc.PtyServerSupervisor.
    # The claude invocation (argv list + cmd_env) is built here in the
    # cc plugin and handed to Server as :cmd_override / :cmd_env,
    # keeping ezagent_domain_pty Tier-2.
    #
    # In `:test` env we deliberately SKIP the McpConfigWriter side
    # effect — the Server short-circuits `:exec.run/2` via `test_mode:
    # true` (Mix.env() default), so the invocation is never spawned;
    # building it would write `~/.ezagent/bridge.mcp.json` to disk on
    # every test, which the pre-Domain.Pty-PR-A path also avoided.
    #
    # `build_claude_cmd/3` may fail with `{:error, :claude_not_found}`
    # when `claude` is not on `PATH` — argv element 0 must be an
    # absolute path because erlexec's list-form `:exec.run/2` runs
    # `execve(3)` with NO shell and NO PATH search (see its docstring).
    # The `with` propagates that error so instantiate/3 fails clearly
    # rather than spawning a PtyServer whose `claude` will never start.
    with {:ok, params} <- build_pty_params(agent_uri, cwd, tmpl),
         {:ok, _pid} <- start_pty(agent_uri, params) do
      :ok
    end
  end

  defp build_pty_params(agent_uri, cwd, tmpl) do
    case Mix.env() do
      :test ->
        {:ok, %{cwd: cwd, test_mode: true}}

      _ ->
        with {:ok, {argv, cmd_env}} <- build_claude_cmd(agent_uri, cwd, tmpl) do
          {:ok, %{cwd: cwd, cmd_override: argv, cmd_env: cmd_env}}
        end
    end
  end

  defp start_pty(agent_uri, params) do
    case Ezagent.Domain.Pty.start(agent_uri, params) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Atomic dedup at supervisor layer (PtyServer's :via Registry
        # name made this happen). Treat as success.
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: PtyServer start failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:pty_server_spawn_failed, reason}}
    end
  end

  # Phase 6 PR 23 + Domain.Pty PR-A (2026-05-21): build the full
  # claude invocation cc agents run under PTY. Moved here from
  # `Ezagent.PluginCc.PtyServer.spawn_claude_directly/1` so the Server
  # module (now `Ezagent.Domain.Pty.Server`) stays Tier-2 — no
  # dependency on cc-plugin modules like `McpConfigWriter`.
  # `agent_cwd` is always supplied by the sole caller
  # (ensure_pty_server/3) — no default, per dead-code audit 2026-05-21.
  #
  # Phase 7 completion PR-1 (SPEC §1.5 (c)): `tmpl` may carry the four
  # optional sandbox keys.
  #
  # codex HIGH-2 — the invocation is built as an **argv list**, NOT a
  # shell string. `Ezagent.Domain.Pty` runs a list-form `cmd_override`
  # via `execve` with NO shell, so each element is exactly one
  # `argv[]` entry. An operator-controlled sandbox path
  # (`operator_settings_path` / `operator_mcp_config_path`) is one list
  # element — it can neither split into extra arguments (defeating the
  # rev-5 "mandatory `--settings` last-wins" guarantee) nor smuggle a
  # shell command. `claude_config_dir` is returned as a structured env
  # var (`CLAUDE_CONFIG_DIR`), NOT a `VAR=val` shell prefix (a prefix
  # is meaningless in argv form and was shell-injectable in string
  # form).
  #
  # codex review of the PR-1 hardening (#233) — argv element 0 MUST be
  # an ABSOLUTE PATH. erlexec's list-form `:exec.run/2` goes straight
  # to `execve(3)` (no shell, no `$PATH` search), so a bare `"claude"`
  # would only resolve if it happened to live in `cwd`. The pre-#233
  # shell-string path resolved `claude` via `$PATH`; the no-shell argv
  # refactor regressed that. We restore PATH resolution here by calling
  # `System.find_executable("claude")` — and if `claude` is not on
  # `PATH` we return `{:error, :claude_not_found}` (NO silent shell
  # fallback) so the caller fails loudly rather than spawning a PTY
  # whose child can never start.
  #
  # Returns `{:ok, {argv_list, env_map}}` or `{:error, :claude_not_found}`.
  defp build_claude_cmd(agent_uri, agent_cwd, tmpl) do
    with {:ok, claude_path} <- resolve_claude_executable(agent_uri) do
      # `write_with_token!/1` returns the per-instance connect token in
      # addition to the esr-bridge mcp.json path. Exporting the agent
      # URI + that token into the `claude` PROCESS env (`cmd_env`)
      # means every MCP server `claude` launches — including the
      # orchestrator MCP transport bridge (`orchestrator_bridge.py`),
      # which an operator `--mcp-config` adds — inherits the same
      # per-instance identity and can authenticate its own WS Channel
      # join. Minting is idempotent per agent URI, so this is the SAME
      # token baked into the esr-bridge config: one credential, no
      # spoofing surface (Phase 7 completion PR-5).
      {:ok, mcp_path, agent_token} =
        EzagentPluginCc.McpConfigWriter.write_with_token!(
          agent_uri: URI.to_string(agent_uri),
          agent_cwd: agent_cwd
        )

      settings_mcp_args = assemble_settings_mcp_args(mandatory_settings_path(), mcp_path, tmpl)

      # argv element 0 is the resolved ABSOLUTE path (not bare
      # "claude"); the rest is the hardening's safe arg assembly,
      # unchanged.
      argv =
        [
          claude_path,
          "--permission-mode",
          "bypassPermissions",
          "--dangerously-load-development-channels",
          "server:esr-bridge"
        ] ++ settings_mcp_args

      base_env = %{
        # Inherited by every MCP-server subprocess `claude` spawns.
        "EZAGENT_AGENT_URI" => URI.to_string(agent_uri),
        "EZAGENT_AGENT_TOKEN" => agent_token
      }

      cmd_env =
        case Map.get(tmpl, "claude_config_dir") do
          dir when is_binary(dir) and dir != "" ->
            Map.put(base_env, "CLAUDE_CONFIG_DIR", dir)

          _ ->
            base_env
        end

      {:ok, {argv, cmd_env}}
    end
  end

  @doc false
  # codex review of the PR-1 hardening (#233) — resolve the `claude`
  # executable to an ABSOLUTE PATH via `System.find_executable/1`.
  #
  # erlexec's list-form `:exec.run/2` (the no-shell argv path the
  # hardening adopted) runs `execve(3)` directly: there is no shell, so
  # no `$PATH` lookup. A bare `"claude"` as argv element 0 only
  # resolves if `claude` happens to live in `cwd`. `System.find_executable/1`
  # reproduces the `$PATH` search the pre-#233 shell-string path got
  # for free, so the resolved absolute path can be handed to `execve`.
  #
  # Returns `{:ok, absolute_path}` or `{:error, :claude_not_found}`.
  # The not-found case is a clear, propagated error — there is NO
  # silent fall back to a shell-resolved invocation.
  #
  # Exposed (`@doc false`) so the regression test can drive PATH
  # resolution + the no-claude error path directly.
  @spec resolve_claude_executable(URI.t()) :: {:ok, String.t()} | {:error, :claude_not_found}
  def resolve_claude_executable(agent_uri) do
    case System.find_executable("claude") do
      nil ->
        Logger.error(
          "cc.agent: `claude` executable not found on PATH for " <>
            "#{URI.to_string(agent_uri)} — cannot build the argv invocation. " <>
            "erlexec list-form exec runs execve(3) with no PATH search, so " <>
            "argv element 0 must be an absolute path. Install `claude` on the " <>
            "PATH of the process running `mix phx.server`."
        )

        {:error, :claude_not_found}

      claude_path ->
        {:ok, claude_path}
    end
  end

  # The plugin-shipped mandatory safety settings file. Phase 6 PR 23:
  # operator's `~/.claude/settings.json` may set `remoteControlAtStartup:
  # true` (cc-openclaw + others enable it) — that redirects interactive
  # I/O to claude.ai cloud + makes the local PTY a passive observer.
  # This file forces `remoteControlAtStartup: false`.
  defp mandatory_settings_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join("claude-pty-settings.json")
  end

  @doc false
  # Phase 7 completion PR-1 (SPEC §1.5 (c)) — pure assembly of the
  # `--settings` / `--mcp-config` argv sequence. Exposed (`@doc false`)
  # so the adversarial-path test can assert the ordering + injection
  # invariants without the McpConfigWriter side effect.
  #
  # codex HIGH-2 — returns an **argv LIST** where every flag and every
  # path is a SEPARATE element (`["--settings", "/a/b", ...]`), NOT a
  # space-joined string. The list is handed verbatim to
  # `:exec.run/2`'s argv form (no shell). Consequences:
  #
  #   * An operator `operator_settings_path` / `operator_mcp_config_path`
  #     is ONE element. A value like `/tmp/x.json --settings /tmp/evil`
  #     stays a single `argv[]` entry — claude receives it as one
  #     (nonsense) file path; it CANNOT introduce a later `--settings`
  #     flag, so the rev-5 "mandatory `--settings` last-wins" guarantee
  #     holds for every possible operator value.
  #   * Spaces, `;`, `$(...)`, backticks, `&&` in an operator value are
  #     inert — there is no shell to interpret them.
  #
  # SAFETY INVARIANT — the mandatory plugin `--settings` is emitted
  # LAST. claude's `--settings` is last-wins, so a hostile operator
  # `operator_settings_path` setting `remoteControlAtStartup: true`
  # cannot win: the mandatory file (forcing `false`) is layered after
  # it. An operator `--settings` is emitted FIRST (it may layer
  # non-conflicting keys; conflicting safety keys lose).
  #
  # The trusted esr-bridge `--mcp-config` is ALWAYS emitted; an
  # operator `--mcp-config` is an ADDITIONAL flag, never a replacement
  # (claude merges MCP configs additively — an operator config adds
  # servers but cannot delete the bridge server).
  @spec assemble_settings_mcp_args(String.t(), String.t(), map()) :: [String.t()]
  def assemble_settings_mcp_args(mandatory_settings_path, bridge_mcp_path, tmpl)
      when is_binary(mandatory_settings_path) and is_binary(bridge_mcp_path) and is_map(tmpl) do
    operator_settings =
      case Map.get(tmpl, "operator_settings_path") do
        p when is_binary(p) and p != "" -> ["--settings", p]
        _ -> []
      end

    operator_mcp =
      case Map.get(tmpl, "operator_mcp_config_path") do
        p when is_binary(p) and p != "" -> ["--mcp-config", p]
        _ -> []
      end

    # Order: operator --settings FIRST, mandatory --settings LAST
    # (last-wins ⇒ safety non-bypassable). The trusted bridge
    # --mcp-config is always present; an operator --mcp-config is
    # additive (listed after the bridge). Each flag + each path is its
    # OWN list element — an operator value is never split or able to
    # become a new flag (codex HIGH-2).
    operator_settings ++
      ["--settings", mandatory_settings_path] ++
      ["--mcp-config", bridge_mcp_path] ++
      operator_mcp
  end

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  defp pty_server_alive?(agent_uri), do: Ezagent.Domain.Pty.alive?(agent_uri)

  # --- Ezagent.UI.Form ---------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/<workspace>/cc_<name>)",
        required: true,
        placeholder: "entity://agent/default/cc_architect"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory",
        required: true,
        placeholder: "/Users/me/Workspace/proj"
      }
    ]
  end
end
