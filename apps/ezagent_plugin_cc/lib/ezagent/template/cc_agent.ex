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
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
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
        spawn_for_local_pty(agent_uri, tmpl, workspace_uri)
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
  defp spawn_for_local_pty(agent_uri, tmpl, workspace_uri) do
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
          # Codex PR3 round-2 HIGH-2 — DO NOT call create_agent_config_dir
          # from the loser branch. A concurrent :started winner may be
          # mid-cp_r (marker not yet written); the loser would see
          # marker-absent and rm_rf the dir the winner is still copying.
          # The winner is responsible for dir creation; the loser just
          # adopts. The Agent slice was already populated by the
          # winner's record_sandbox_state when it spawned — slice still
          # carries the path.
          #
          # We also do NOT supply :config_dir_path in meta. The caller's
          # record_sandbox_state skips slice-dispatch when meta lacks
          # :config_dir_path (codex round-2 HIGH-1 fix in Agent module),
          # so the existing slice is preserved verbatim.
          #
          # PTY-orphan-restart 2026-05-26 round-2 (codex finding #1):
          # the :already_started branch USED to return immediately,
          # which leaves a Kind alive without a PtyServer in the
          # demand-spawn case (chat router spawned the Kind first;
          # then Workspace.Loader hits this branch and short-circuits).
          # Round-8's "refuse to adopt foreign Kind" stays correct AS
          # AN INVARIANT — we only bring up the PTY when we can prove
          # the agent belongs to THIS workspace by URI-segment match.
          # When the agent's workspace segment matches `workspace_uri`,
          # the operator's workspace template legitimately owns this
          # URI (this is the boot/demand-restore case Workspace.Loader
          # hits). When it does NOT match, this is a cross-workspace
          # adoption attempt (codex round-8's test case) — we MUST
          # refuse the PTY spawn.
          if owns_this_agent?(agent_uri, workspace_uri) do
            _ = ensure_subprocess_alive_best_effort(agent_uri, tmpl)
          end

          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          # codex round-10 HIGH-2 + PR3 2026-05-24 cascade:
          # 1. Create per-agent config_dir BEFORE PTY launch (so the
          #    cc process gets `CLAUDE_CONFIG_DIR=<per-agent-dir>`
          #    immediately).
          # 2. If config_dir creation fails → terminate the freshly-
          #    started Agent Kind (rollback what we created), return
          #    error.
          # 3. Thread `agent_config_dir` into `tmpl` so `build_claude_cmd/3`
          #    reads the PER-AGENT dir (not the template's reference
          #    dir).
          # 4. If `ensure_pty_server/3` fails → terminate the Kind AND
          #    remove the just-created config_dir (full rollback).
          # 5. On full success: return `config_dir_path: dir` AND
          #    `respawn_template_data: tmpl_with_dir` in meta so caller
          #    dispatches `sandbox.write_path` with both. The persisted
          #    respawn data lets Sandbox.post_init/2 call back into
          #    `ensure_subprocess_alive/2` on a phx restart
          #    (PTY-orphan-restart 2026-05-26).
          with {:ok, config_dir} <- create_agent_config_dir(agent_uri, tmpl),
               tmpl_with_dir = put_agent_config_dir(tmpl, config_dir),
               :ok <- ensure_pty_server(agent_uri, cwd, tmpl_with_dir) do
            {:ok, [agent_uri],
             %{
               fresh?: true,
               config_dir_path: config_dir,
               respawn_template_data: tmpl_with_dir
             }}
          else
            {:error, reason} ->
              _ = Ezagent.Kind.terminate(agent_uri)
              rollback_agent_config_dir(agent_uri)
              {:error, reason}
          end
      end
    end
  end

  defp put_agent_config_dir(tmpl, nil), do: tmpl
  defp put_agent_config_dir(tmpl, dir), do: Map.put(tmpl, "agent_config_dir", dir)

  # Roll back a partially-created config dir on PTY-startup failure.
  # Best-effort — failure to remove is logged but does NOT block the
  # error return (the agent's already in an error state, telemetry
  # cares more than additional cleanup retries).
  defp rollback_agent_config_dir(agent_uri) do
    dir = agent_config_dir(agent_uri)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _path} ->
        Logger.warning(
          "cc.agent: rollback of #{dir} failed: #{inspect(reason)} " <>
            "(agent_uri=#{URI.to_string(agent_uri)})"
        )

        :ok
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

  # Exposed (`@doc false`) so the spawn-path invariant test (added
  # 2026-05-26 alongside the mention-parser regression fix) can
  # exercise the production param-building path without spawning a
  # real PTY. Test:
  # `apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_spawn_invariant_test.exs`.
  @doc false
  def build_pty_params(agent_uri, cwd, tmpl) do
    build_pty_params_for_env(agent_uri, cwd, tmpl, Mix.env())
  end

  # Codex 2026-05-26 MEDIUM — splitting the env axis out lets the
  # invariant test pass `:dev` directly to assert the production Map
  # shape (key name `:cmd_override` is the Domain.Pty.Server boundary
  # contract — a future refactor that renames it would silently leave
  # the Server without a child program → no claude → no bridge).
  @doc false
  def build_pty_params_for_env(agent_uri, cwd, tmpl, env) do
    case env do
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
  #
  # Exposed (`@doc false`) so the spawn-path invariant test
  # (`cc_agent_spawn_invariant_test.exs`, 2026-05-26) can assert the
  # full production argv shape — `claude` (resolved abs path) as
  # element 0, the safety `--settings` LAST, the bridge `--mcp-config`
  # present, `CLAUDE_CONFIG_DIR` in cmd_env when configured — without
  # rebuilding the assembly in the test (the rebuild-in-test pattern
  # used by `cc_agent_sandbox_credentials_test.exs` line 521 is fragile
  # — a divergence between the test's rebuild and the production
  # builder passes the test while production breaks).
  @doc false
  def build_claude_cmd(agent_uri, agent_cwd, tmpl) do
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
      {:ok, _global_mcp_path, agent_token} =
        EzagentPluginCc.McpConfigWriter.write_with_token!(
          agent_uri: URI.to_string(agent_uri),
          agent_cwd: agent_cwd
        )

      # 2026-05-26 (Allen e2e Bug 4): the writer writes THREE copies of
      # the bridge mcp.json:
      #   (a) `~/.ezagent/bridge.mcp.json` — shared/global, LATEST-WRITE-WINS
      #   (b) `<git toplevel>/.mcp.json`  — shared/global, LATEST-WRITE-WINS
      #   (c) `<agent_cwd>/.mcp.json`     — per-agent, isolated
      #
      # Pre-fix, `--mcp-config` pointed at (a). When two cc agents were
      # spawned in succession, agent N's TUI would read (a) which had
      # been clobbered by agent M's later spawn — claude's python bridge
      # subprocess would authenticate as M, never connect for N. The
      # observable symptom: only ONE cc agent ever has an active
      # `cc:bridge:<URI>` channel (the last one spawned), and every
      # other agent's inbound `chat.receive` audits as `:no_bridge`
      # → silent drop.
      #
      # Per-agent isolation: claude's `--mcp-config` now points at the
      # per-agent `<cwd>/.mcp.json` (write site (c)). That file's lifetime
      # is bound to the agent's cwd; no other agent overwrites it.
      # Files (a) + (b) are now diagnostic surfaces only (operator can
      # eyeball the last-spawned agent's creds; they no longer gate
      # the runtime claude → bridge handshake).
      per_agent_mcp_path = Path.join(agent_cwd, ".mcp.json")
      settings_mcp_args = assemble_settings_mcp_args(mandatory_settings_path(), per_agent_mcp_path, tmpl)

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

      # PR3 2026-05-24 + codex round-1 MEDIUM-1 — the per-agent dir
      # takes precedence over the template's reference dir. Both are
      # validated as non-empty binaries up-front (a previous `cond`
      # binding form silently let `""` win the branch and DROP
      # CLAUDE_CONFIG_DIR — hiding template misconfiguration).
      #
      # If BOTH keys are present but `agent_config_dir` is invalid,
      # we raise rather than fall back — a freshly-spawned agent
      # whose per-agent dir was misset would otherwise silently use
      # the SHARED template ref dir (cross-agent credential leak).
      cmd_env = build_claude_config_env(base_env, tmpl)

      {:ok, {argv, cmd_env}}
    end
  end

  # Strict precedence — codex PR3 round-1 MEDIUM-1.
  # 1. valid `agent_config_dir` → use it
  # 2. invalid `agent_config_dir` (present but not valid binary) AND
  #    `claude_config_dir` also present → RAISE (would silently leak
  #    cross-agent credentials via shared ref dir)
  # 3. no `agent_config_dir` + valid `claude_config_dir` → use it (legacy)
  # 4. neither valid → no CLAUDE_CONFIG_DIR (claude uses ~/.claude)
  defp build_claude_config_env(base_env, tmpl) do
    agent_dir = Map.get(tmpl, "agent_config_dir")
    template_dir = Map.get(tmpl, "claude_config_dir")

    cond do
      valid_dir?(agent_dir) ->
        Map.put(base_env, "CLAUDE_CONFIG_DIR", agent_dir)

      not is_nil(agent_dir) and valid_dir?(template_dir) ->
        raise ArgumentError,
              "cc.agent: invalid agent_config_dir #{inspect(agent_dir)} but " <>
                "claude_config_dir is also present — refusing to fall back to " <>
                "the shared template reference dir (cross-agent credential leak risk). " <>
                "Fix the per-agent dir creation."

      valid_dir?(template_dir) ->
        Map.put(base_env, "CLAUDE_CONFIG_DIR", template_dir)

      true ->
        base_env
    end
  end

  defp valid_dir?(d) when is_binary(d) and d != "", do: true
  defp valid_dir?(_), do: false

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

  # --- Per-agent config_dir + extension management (PR3 2026-05-24) -----------
  #
  # Allen 2026-05-24 architectural decision (PR2 + PR3): every spawned cc
  # agent gets its OWN config dir (copied from the template's reference
  # `claude_config_dir` at spawn). The dir is the per-agent CLAUDE_CONFIG_DIR
  # — claude reads `.credentials.json` etc. from it — and houses an
  # installable extensions tree at `<dir>/.claude/plugins/<ext_id>/`
  # (Anthropic Claude Code "plugin" bundles, per the marketplace cache
  # convention at `~/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/`).
  #
  # cc Template Class implements ALL THREE extension callbacks together
  # (the all-or-nothing invariant in
  # `apps/ezagent_core/test/invariants/template_class_extension_contract_test.exs`
  # enforces this).

  # PR3 layout — what `agent_config_dir/1` looks like on disk:
  #
  #   <Ezagent.Home.path("cc-agents")>/<workspace>/<flavor>_<name>/   (chmod 700)
  #   ├── .credentials.json                        (chmod 600 — copied from template)
  #   └── .claude/
  #       └── plugins/
  #           ├── <ext_id_1>/.claude-plugin/plugin.json
  #           └── <ext_id_2>/...
  #
  # `agent_config_dir/1` is the canonical path builder; the cleanup
  # callback (`destroy_config_dir/2`) verifies the path it removes
  # equals this — defense-in-depth against being handed a bogus path.

  @doc false
  def agent_config_dir(%URI{} = agent_uri) do
    workspace = agent_workspace_segment(agent_uri)
    name = agent_name_segment(agent_uri)
    Path.join([Ezagent.Home.path("cc-agents"), workspace, name])
  end

  defp agent_workspace_segment(%URI{host: "agent", path: "/" <> rest} = agent_uri) do
    case String.split(rest, "/", parts: 2) do
      [workspace, _name] when workspace != "" ->
        workspace

      _ ->
        raise ArgumentError,
              "agent URI is not canonical 3-segment `entity://agent/<workspace>/<name>` " <>
                "— got #{inspect(agent_uri)}. Per SPEC #324 rev 3 / PR #335, there is NO " <>
                "silent default workspace fallback; callers must pass a fully-formed URI."
    end
  end

  defp agent_workspace_segment(other),
    do:
      raise(
        ArgumentError,
        "agent URI is not an `entity://agent/...` URI — got #{inspect(other)}. " <>
          "Per SPEC #324 rev 3 / PR #335, there is NO silent default workspace fallback; " <>
          "callers must pass a fully-formed URI."
      )

  defp agent_name_segment(%URI{host: "agent", path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, name] when name != "" -> name
      _ -> "unknown"
    end
  end

  defp agent_name_segment(_), do: "unknown"

  # `list_extensions/1` — scan `<config_dir>/.claude/plugins/*` for
  # installed Claude Code plugin bundles. A bundle is recognized by
  # `<dir>/.claude-plugin/plugin.json` (the manifest the
  # Anthropic CC marketplace stores). The manifest's `name` / `description`
  # surface in the LV; the directory NAME is the `id` (operators can
  # rename bundles by dir-rename, but the LV uses dir-name as the
  # stable handle).
  @impl Ezagent.Kind.Template
  def list_extensions(config_dir) when is_binary(config_dir) do
    plugins_dir = Path.join([config_dir, ".claude", "plugins"])

    case File.ls(plugins_dir) do
      {:ok, entries} ->
        extensions =
          entries
          |> Enum.filter(fn name -> File.dir?(Path.join(plugins_dir, name)) end)
          |> Enum.map(fn dir_name -> read_extension_manifest(plugins_dir, dir_name) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.name)

        {:ok, extensions}

      {:error, :enoent} ->
        # No plugins dir yet (agent has none installed). Not an error.
        {:ok, []}

      {:error, reason} ->
        {:error, {:list_plugins_failed, reason}}
    end
  end

  def list_extensions(_), do: {:error, :invalid_config_dir}

  # Read `<plugins_dir>/<dir_name>/.claude-plugin/plugin.json` and turn
  # it into the standard extension descriptor. Returns `nil` if the dir
  # is NOT a plugin bundle (no manifest) — those are silently filtered
  # out (operator dropped some unrelated file in plugins/).
  defp read_extension_manifest(plugins_dir, dir_name) do
    manifest_path = Path.join([plugins_dir, dir_name, ".claude-plugin", "plugin.json"])

    with {:ok, body} <- File.read(manifest_path),
         {:ok, json} <- Jason.decode(body) do
      %{
        id: dir_name,
        name: Map.get(json, "name", dir_name),
        description: Map.get(json, "description", ""),
        # presence-in-dir == enabled (uninstalling = toggle off = rmdir)
        enabled?: true
      }
    else
      _ -> nil
    end
  end

  # `toggle_extension/3` — install or uninstall an extension bundle in
  # the per-agent config dir.
  #
  # PR3 V1 scope: TOGGLE-OFF only is fully implemented (= `rm -rf`
  # `<config_dir>/.claude/plugins/<ext_id>/`). TOGGLE-ON is NOT
  # implemented yet — needs a SOURCE (a marketplace registry / a
  # known plugin cache to copy FROM); the LV will surface a
  # "Unsupported: install from marketplace" message until that
  # source is wired (separate PR — likely once marketplace integration
  # lands). For now `toggle_extension(_, _, true)` returns
  # `{:error, :install_from_source_not_implemented}` so the LV can
  # render a clear "not yet available" hint.
  @impl Ezagent.Kind.Template
  def toggle_extension(config_dir, extension_id, enabled?)
      when is_binary(config_dir) and is_binary(extension_id) and is_boolean(enabled?) do
    target = Path.join([config_dir, ".claude", "plugins", extension_id])

    cond do
      # Pre-validate extension_id BEFORE Path.join can do anything
      # dangerous (an absolute path or `/` segment would otherwise
      # let toggle escape the plugins dir).
      not valid_extension_id?(extension_id) ->
        {:error, :unsafe_extension_path}

      # Belt-and-braces post-join check.
      not safe_extension_path?(config_dir, target) ->
        {:error, :unsafe_extension_path}

      enabled? == false ->
        case File.rm_rf(target) do
          {:ok, _removed} -> :ok
          {:error, reason, _path} -> {:error, {:rm_failed, reason}}
        end

      enabled? == true ->
        # PR3 V1: install-from-source is deferred to the marketplace
        # PR. An operator can still install manually (`cp -r` a bundle
        # under `<config_dir>/.claude/plugins/`); the LV reflects the
        # new state on next refresh.
        {:error, :install_from_source_not_implemented}
    end
  end

  def toggle_extension(_, _, _), do: {:error, :invalid_args}

  # Defense-in-depth: the target plugin path MUST be under the agent's
  # `<config_dir>/.claude/plugins/` subtree. A maliciously-crafted
  # `extension_id` like `"../../etc"` or `"/etc/passwd"` would
  # otherwise let toggle-off delete arbitrary paths.
  #
  # Three checks (any failure → unsafe):
  #   1. ext_id contains no `/` (would let Path.join concatenate
  #      additional path segments)
  #   2. ext_id is not absolute (would let Path.join replace prefix —
  #      e.g. `Path.join(["/a/b", "/c"])` discards `/a/b`)
  #   3. Path.expand(target) is under Path.expand(plugins_dir) — the
  #      belt + braces final check (catches any tricks the first two
  #      missed)
  defp safe_extension_path?(config_dir, target) do
    plugins_dir = Path.expand(Path.join([config_dir, ".claude", "plugins"]))
    actual = Path.expand(target)
    String.starts_with?(actual, plugins_dir <> "/")
  end

  # Pre-validate the extension_id BEFORE it gets near Path.join.
  defp valid_extension_id?(ext_id) when is_binary(ext_id) and ext_id != "" do
    not String.contains?(ext_id, "/") and
      not String.contains?(ext_id, "\\") and
      ext_id != "." and
      ext_id != ".."
  end

  defp valid_extension_id?(_), do: false

  # `destroy_config_dir/2` — `rm -rf <config_dir>`. Called at agent
  # teardown by `Ezagent.Behavior.Sandbox.invoke(:destroy, ...)`.
  #
  # Defense-in-depth: the path MUST equal what `agent_config_dir/1`
  # would compute for this agent_uri. A buggy caller passing an
  # arbitrary path (e.g. `/`) would otherwise be catastrophic.
  @impl Ezagent.Kind.Template
  def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
    expected = agent_config_dir(agent_uri)

    if Path.expand(config_dir) == Path.expand(expected) do
      case File.rm_rf(config_dir) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, {:rm_rf_failed, reason}}
      end
    else
      {:error, {:path_mismatch, expected: expected, got: config_dir}}
    end
  end

  def destroy_config_dir(_, _), do: {:error, :invalid_args}

  # --- PTY-orphan-restart 2026-05-26 — re-spawn the claude PTY on boot ------
  #
  # Invoked by `Ezagent.Behavior.Sandbox`'s post_init/2 continuation
  # after the Agent Kind has been rehydrated from snapshot on a phx
  # restart. We check whether the PtyServer (which OWNS the claude TUI
  # subprocess) is alive for this agent_uri; if absent, we re-run the
  # same `ensure_pty_server/3` path `instantiate/3` uses for fresh
  # spawns.
  #
  # ## Why this is needed
  #
  # The two-layer process model:
  #   1. Agent Kind (Elixir GenServer) — OTP-supervised, recovers from
  #      snapshot.
  #   2. PtyServer + claude TUI subprocess — NOT OTP-supervised across
  #      BEAM restarts. Dies with the BEAM (or worse, survives as an
  #      OS orphan on brutal kill).
  #
  # On a normal `instantiate/3` boot path the codex round-8 fix
  # IMMEDIATELY returns when the Agent Kind is `:already_started` —
  # without starting the PTY. That's correct for the "foreign Kind
  # adoption" case but it CAN'T be the boot-restore path. The
  # boot-restore path goes through this callback instead, which knows
  # the agent is OURS (it was OURS at original-spawn time; the
  # respawn_template_data was persisted into our sandbox slice then).
  #
  # ## Idempotency
  #
  # `Ezagent.Domain.Pty.alive?/1` is the single source of truth. If
  # YES, return :ok (subprocess survived the restart somehow — would
  # only happen in a hot-code-update scenario; under normal
  # SIGTERM/SIGKILL → BEAM restart, the PtyServer dies + the OS
  # claude is reaped by erlexec OR by our OrphanReaper).
  #
  # On failure we return `{:error, reason}` — Sandbox.post_init/2
  # re-raises and the Kind.Server supervisor restarts with backoff
  # (`feedback_let_it_crash_no_workarounds`).
  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    cond do
      pty_server_alive?(agent_uri) ->
        :ok

      true ->
        # PtyServer absent — rebuild it from the persisted respawn data.
        # `cwd` is required in respawn_data per `check_cwd/1`; the rest
        # of the keys are optional and may carry the agent_config_dir
        # added at spawn-time (so we don't recreate the config dir
        # here — the snapshot is the source of truth for it).
        case Map.fetch(respawn_data, "cwd") do
          {:ok, cwd} when is_binary(cwd) and cwd != "" ->
            case ensure_pty_server(agent_uri, cwd, respawn_data) do
              :ok ->
                Logger.info(
                  "cc.agent.ensure_subprocess_alive: respawned PtyServer for " <>
                    URI.to_string(agent_uri)
                )

                :ok

              {:error, reason} = err ->
                Logger.error(
                  "cc.agent.ensure_subprocess_alive: failed to respawn PtyServer for " <>
                    "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
                )

                err
            end

          _ ->
            {:error, {:missing_cwd_in_respawn_data, agent_uri}}
        end
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  # Cross-workspace adoption gate (codex round-2 finding #1). We only
  # bring up a PTY for an already-started Kind when the agent URI's
  # workspace segment matches the workspace we're being instantiated
  # into. A mismatch means "another workspace's template is referencing
  # our URI" — we must refuse (preserves codex round-8 invariant).
  defp owns_this_agent?(%URI{} = agent_uri, %URI{} = workspace_uri) do
    case agent_uri do
      %URI{scheme: "entity", host: "agent", path: "/" <> rest} ->
        case String.split(rest, "/", parts: 2) do
          [ws_segment, _name] when is_binary(ws_segment) -> ws_segment == workspace_uri.host
          _ -> false
        end

      _ ->
        false
    end
  end

  # When workspace_uri is nil (legacy callers that don't thread it),
  # default to false — preserves the codex round-8 invariant for
  # callers that don't know about the round-2 fix.
  defp owns_this_agent?(_agent_uri, nil), do: false
  defp owns_this_agent?(_, _), do: false

  # Wrapper for `instantiate/3`'s `:already_started` branch (codex
  # round-2 finding #1). Calls `ensure_subprocess_alive/2` but never
  # propagates its error — the adopted-Kind path's invariant is "this
  # call did not create the Kind, so we don't tear it down on
  # subprocess failure either". A failed PTY respawn leaves the Kind
  # alive but degraded; operator sees the failure via logs/health
  # panel and clicks Restart manually.
  defp ensure_subprocess_alive_best_effort(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    case ensure_subprocess_alive(agent_uri, tmpl) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "cc.agent.instantiate(:already_started): ensure_subprocess_alive failed for " <>
            "#{URI.to_string(agent_uri)} (#{inspect(reason)}); Kind remains alive in " <>
            "degraded state (no PTY) — operator may need to Restart manually"
        )

        {:error, reason}
    end
  end

  # Create a fresh per-agent config dir by copying the template's
  # reference dir into the agent-private location.
  #
  # Called from `spawn_for_local_pty/2` BEFORE PTY launch so the
  # cc process gets `CLAUDE_CONFIG_DIR=<per-agent-dir>` and reads its
  # own private credentials/settings. The reference dir is the
  # template's `claude_config_dir` field (now interpreted as
  # "reference" — not the dir the process actually uses).
  #
  # Returns `{:ok, path}` where path is the absolute per-agent dir.
  # If no reference dir is configured on the template, returns
  # `{:ok, nil}` — agent runs without `CLAUDE_CONFIG_DIR` (legacy
  # behavior, valid for agents that need no sandbox).
  @doc false
  @spec create_agent_config_dir(URI.t(), map()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def create_agent_config_dir(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    reference_dir = Map.get(tmpl, "claude_config_dir")

    case reference_dir do
      ref when is_binary(ref) and ref != "" ->
        do_create_agent_config_dir(agent_uri, ref)

      _ ->
        # No reference dir on template — the agent runs without one
        # (legacy: claude reads from `~/.claude` on the operator's
        # machine). The Sandbox slice's config_dir_path will be nil.
        {:ok, nil}
    end
  end

  # Marker file written at the END of a successful copy. The dir is
  # considered "valid" ONLY if the marker exists — a half-copied dir
  # (process killed mid-cp_r) or stale leftover lacks the marker and
  # gets fully re-created. Codex PR3 round-1 HIGH-2.
  @config_complete_marker ".ezagent-config-complete"

  defp do_create_agent_config_dir(agent_uri, reference_dir) do
    target = agent_config_dir(agent_uri)
    marker = Path.join(target, @config_complete_marker)

    cond do
      not File.dir?(reference_dir) ->
        {:error, {:reference_dir_missing, reference_dir}}

      File.dir?(target) and File.exists?(marker) ->
        # Already exists AND marker present → completed copy from a
        # prior spawn. Idempotent — return the path (live state).
        {:ok, target}

      File.dir?(target) ->
        # Stale / partially-copied dir (marker absent). Wipe + re-copy
        # rather than silently adopting corrupted state. Codex PR3
        # round-1 HIGH-2: a partial cp_r leaves missing files; PTY
        # would launch with corrupt credentials. Better to fail loudly
        # and re-create than ignore.
        case File.rm_rf(target) do
          {:ok, _} ->
            do_atomic_copy(reference_dir, target, marker)

          {:error, reason, _} ->
            {:error, {:stale_dir_cleanup_failed, reason}}
        end

      true ->
        do_atomic_copy(reference_dir, target, marker)
    end
  end

  # Copy + chmod + write marker as the LAST step. If anything before
  # the marker fails, the next spawn sees marker-absent → wipes + retries.
  defp do_atomic_copy(reference_dir, target, marker) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _} <- File.cp_r(reference_dir, target),
         :ok <- File.chmod(target, 0o700),
         :ok <- chmod_credentials(target),
         :ok <- File.write(marker, "ok\n") do
      {:ok, target}
    else
      {:error, reason} -> {:error, {:copy_reference_dir_failed, reason}}
      err -> {:error, {:copy_reference_dir_failed, err}}
    end
  end

  # The seed convention chmods `.credentials.json` to 0600 (file
  # contains the Anthropic API key). Mirror that here so a copy
  # preserves the convention even if the operator's reference dir
  # had laxer perms.
  defp chmod_credentials(dir) do
    creds = Path.join(dir, ".credentials.json")

    case File.exists?(creds) do
      true -> File.chmod(creds, 0o600)
      false -> :ok
    end
  end

  # --- Ezagent.UI.Form ---------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/<workspace>/cc_<name>)",
        required: true,
        placeholder: "entity://agent/team-alpha/cc_architect"
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
