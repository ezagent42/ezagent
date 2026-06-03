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

  Extended form (Phase 7 completion PR-1, SPEC §1.5 (c)) — the
  AgentTemplate→cc adapter (`Ezagent.Entity.AgentTemplate.to_template_data/2`)
  threads these OPTIONAL keys:

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path",
        "config_dir" => "/path/to/per-agent/.claude",
        "operator_settings_path" => "/path/to/operator/settings.json",
        "operator_mcp_config_path" => "/path/to/operator/mcp.json",
        "api_key_helper" => "/path/to/api-key-helper.sh"
      }

  `"config_dir"` is the UNIVERSAL, flavor-neutral per-agent config-home
  data key (Allen 2026-06-03): every flavor's `AgentTemplate` emits it; the
  cc Template Class READS it and applies claude semantics (it copies the
  dir per-agent and exports `CLAUDE_CONFIG_DIR`). It is NOT a cc-named
  `"claude_config_dir"` key. All extended keys are optional — absent ⇒ the
  legacy behavior,
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
  it cannot execute a shell command. The universal `config_dir` is passed
  as a structured `CLAUDE_CONFIG_DIR` env var via the Server`s `:cmd_env`
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

  # Compile-time env capture. `Mix.env()` is NOT available in a compiled
  # release (Mix is not loaded — see migration_gate.ex), so calling it at
  # runtime would crash the orchestrator PTY spawn path. The deployment env
  # is fixed at compile time, so a module attribute is both release-safe and
  # correct. (codex final-review Q1.)
  @compile_env Mix.env()

  @impl Ezagent.Kind.Template
  def template_name, do: "cc.agent"

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): the
  # cc-specific template_data fields formerly hardcoded in
  # `AgentTemplate.to_template_data/2`. Reads atom-or-string content keys;
  # returns string keys; nil values are dropped by the caller. Output is
  # byte-for-byte the pre-fix cc set, so orchestrators + existing cc agents
  # are unaffected.
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    # config_dir promotion (Allen 2026-06-03): `config_dir` is now a
    # UNIVERSAL AgentTemplate field — `AgentTemplate.to_template_data/2`
    # emits it in the universal base under the flavor-neutral `"config_dir"`
    # data key. cc does NOT re-emit it here; cc's consume path
    # (`build_claude_config_env/2` / `create_agent_config_dir/2`) READS the
    # neutral `"config_dir"` key and applies claude semantics
    # (`CLAUDE_CONFIG_DIR`, the per-agent copy, the claude file format).
    # Only the cc-specific extras remain owned here.
    %{
      "operator_settings_path" => content_field(content, :settings_path),
      "operator_mcp_config_path" => content_field(content, :mcp_config_path),
      "api_key_helper" => content_field(content, :api_key_helper),
      "role" => content_field(content, :role)
    }
  end

  def template_data_extra(_), do: %{}

  # AgentTemplate `content` may carry atom (fresh) or string (post-JSON)
  # keys — read tolerantly.
  defp content_field(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      v -> v
    end
  end

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_no_stale_config_dir_key(tmpl),
         :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_sandbox_keys(tmpl),
         :ok <- check_role(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  # config_dir promotion (Allen 2026-06-03) — FAIL LOUD on a stale
  # `"claude_config_dir"` data key (codex P2 closure). The per-agent
  # config-home is now the universal, flavor-neutral `"config_dir"` key;
  # `"claude_config_dir"` is NO LONGER part of the contract. A persisted /
  # hand-written template still carrying it would otherwise pass validate
  # (unknown keys are ignored) and then SILENTLY spawn without its isolated
  # config dir / `CLAUDE_CONFIG_DIR` (the consume path reads only
  # `"config_dir"`). Per `feedback_let_it_crash_no_workarounds` (no
  # back-compat shim — DB is wiped + rebuilt), we reject it structurally so
  # the misconfiguration is visible, NOT translated.
  defp check_no_stale_config_dir_key(tmpl) do
    if Map.has_key?(tmpl, "claude_config_dir") do
      {:error,
       {:stale_config_dir_key, "claude_config_dir",
        "config_dir is now the universal, flavor-neutral data key (Allen " <>
          "2026-06-03); rename `claude_config_dir` → `config_dir`. No back-compat " <>
          "shim — see feedback_let_it_crash_no_workarounds."}}
    else
      :ok
    end
  end

  # Phase 7 completion PR-1 (SPEC §1.5 (c)) — the four sandbox keys are
  # OPTIONAL. Absent ⇒ legacy behavior (the 3-key form still validates).
  # When present, each must be a non-empty string.
  # config_dir promotion (Allen 2026-06-03): the per-agent config-home key
  # is the universal, flavor-neutral `"config_dir"` (NOT `"claude_config_dir"`).
  @optional_sandbox_keys ~w(operator_settings_path operator_mcp_config_path
                            config_dir api_key_helper)

  defp check_optional_sandbox_keys(tmpl) do
    Enum.reduce_while(@optional_sandbox_keys, :ok, fn key, :ok ->
      case Map.fetch(tmpl, key) do
        :error -> {:cont, :ok}
        {:ok, v} when is_binary(v) and v != "" -> {:cont, :ok}
        {:ok, bad} -> {:halt, {:error, {:invalid_sandbox_key, key, bad}}}
      end
    end)
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B — `role`
  # is optional. Absent ⇒ default role (legacy cc agents). When
  # orchestrator, `instantiate/3` additionally copies the
  # `ezagent-session-orchestrator` skill into the per-agent config dir
  # and appends a CLAUDE.md hint pointing at it, plus sets
  # `EZAGENT_AGENT_ROLE=orchestrator` in `cmd_env`.
  #
  # codex PR #408 review LOW — accept BOTH string and atom forms on
  # ingress. The SPEC type reads `:default | :orchestrator` (atoms); the
  # implementer chose strings because JSON round-trips don't preserve
  # atoms (snapshot reload). We normalise on read here (validator) AND on
  # read in `orchestrator_role?/1` so callers can pass either form. The
  # CANONICAL on-disk form (seed + AgentTemplate slice) stays the string
  # `"orchestrator"` so snapshot round-trips don't generate atoms (no
  # atom-table-exhaustion exposure); the validator only accepts both
  # shapes so atom-literal call sites compile cleanly.
  defp check_role(tmpl) do
    case Map.fetch(tmpl, "role") do
      :error ->
        :ok

      {:ok, r} when r in ["default", "orchestrator", :default, :orchestrator] ->
        :ok

      {:ok, bad} ->
        {:error, {:invalid_role, bad}}
    end
  end

  defp check_class(%{"class" => "cc.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the structured `{:error, _}` contract for
    # each validator branch.
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity", host: "agent", path: "/" <> rest} when rest != "" ->
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

        %URI{scheme: "entity"} ->
          {:error,
           {:invalid_agent_uri, uri_str,
            "agent URIs must be `entity://agent/<workspace>/cc_<name>` (Phase 9 PR-2)"}}

        _ ->
          {:error, {:bad_agent_uri, uri_str}}
      end
    rescue
      ArgumentError -> {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

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
          #
          # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
          # for role=orchestrator, ALSO load the
          # `ezagent-session-orchestrator` skill into the per-agent
          # config dir (`apply_orchestrator_role_bootstrap/2`) BEFORE
          # PTY launch so claude reads it from `CLAUDE_CONFIG_DIR` on
          # its first start. Idempotent (re-copies / re-appends only if
          # absent).
          #
          # codex PR #408 review HIGH-3 — role-bootstrap is BEST-EFFORT UX:
          # a skill-copy / CLAUDE.md-append failure DOES NOT tear down the
          # agent. The agent still spawns as a plain cc agent; the
          # degraded status surfaces structurally in meta (`role_degraded`)
          # so the caller (Session.ensure_orchestrator) can notify the
          # session owner per Invariant #9 (no silent drops at user-facing
          # surfaces). A telemetry event also fires so monitoring picks up
          # the failure independent of caller wiring. The PTY itself MUST
          # still come up — only role-bootstrap is best-effort, the rest
          # (config_dir, PTY) stays load-bearing.
          with {:ok, config_dir} <- create_agent_config_dir(agent_uri, tmpl),
               tmpl_with_dir = put_agent_config_dir(tmpl, config_dir),
               {:ok, role_meta} <- try_role_bootstrap(tmpl_with_dir, config_dir, agent_uri),
               :ok <- ensure_pty_server(agent_uri, cwd, tmpl_with_dir) do
            base_meta = %{
              fresh?: true,
              config_dir_path: config_dir,
              respawn_template_data: tmpl_with_dir
            }

            {:ok, [agent_uri], Map.merge(base_meta, role_meta)}
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

  # ────────────────────────────────────────────────────────────────────────
  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
  # orchestrator-role bootstrap (skill copy + CLAUDE.md hint).
  # ────────────────────────────────────────────────────────────────────────
  #
  # When the cc template carries `"role" => "orchestrator"`, this helper:
  #
  #   1. Copies the `ezagent-session-orchestrator` skill tree from the
  #      umbrella root into `<config_dir>/skills/ezagent-session-orchestrator/`
  #      via `File.cp_r/2`. Skipped when the destination already exists
  #      (idempotent re-instantiate).
  #   2. Appends `## Use the ezagent-session-orchestrator skill for all
  #      session coordination work.` to `<config_dir>/CLAUDE.md`,
  #      creating the file if missing. Gated on grep-for-marker so a
  #      re-instantiate does NOT duplicate the line.
  #
  # `EZAGENT_AGENT_ROLE=orchestrator` is added to `cmd_env` separately
  # by `build_claude_config_env/2` (so it lands on the claude process
  # even on demand-restart paths that bypass this helper).
  #
  # Failure modes (codex PR #408 review HIGH-3 — degraded-mode return,
  # not teardown — see `spawn_for_local_pty/2` for the post-fix handler):
  #
  #   * Skill source missing (override) — `{:error, {:skill_source_missing, _}}`.
  #   * Skill source missing (auto-walk) — `{:error, {:skill_source_not_found,
  #     attempted_paths}}`.
  #   * `File.cp_r/2` failure — `{:error, {:skill_copy_failed, _}}`.
  #   * CLAUDE.md write failure — `{:error, {:claude_md_hint_failed, _}}`.
  #
  # Skipped when role is `:default` / `"default"` / absent — no-op.
  # Skipped when `config_dir` is `nil` (template has no
  # `config_dir` reference; nowhere to copy the skill).
  @doc false
  @spec apply_orchestrator_role_bootstrap(map(), String.t() | nil) ::
          :ok | {:error, term()}
  def apply_orchestrator_role_bootstrap(_tmpl, nil), do: :ok

  def apply_orchestrator_role_bootstrap(tmpl, config_dir)
      when is_map(tmpl) and is_binary(config_dir) do
    if orchestrator_role?(tmpl) do
      with {:ok, source} <- resolve_orchestrator_skill_source(),
           :ok <- copy_orchestrator_skill(source, config_dir),
           :ok <- append_orchestrator_claude_md_hint(config_dir) do
        :ok
      end
    else
      :ok
    end
  end

  # codex PR #408 review HIGH-3 — wrap `apply_orchestrator_role_bootstrap/2`
  # so a role-bootstrap failure DOES NOT tear down the agent. The agent
  # is allowed to spawn as a plain cc agent (the SKILL is UX, not
  # load-bearing for claude itself).
  #
  # Returns `{:ok, meta}` always when role is non-orchestrator (empty
  # meta) OR role is orchestrator and bootstrap succeeded (empty meta).
  # On bootstrap failure returns `{:ok, %{role_degraded: %{...}}}` — the
  # `:ok` lets the `with` chain in `spawn_for_local_pty/2` continue to
  # `ensure_pty_server/3`. The degraded info propagates up so the caller
  # can notify the session owner (Invariant #9).
  #
  # Emits a `[:ezagent, :cc, :role_bootstrap, :failed]` telemetry event
  # so monitoring observes the failure independent of caller wiring.
  @doc false
  @spec try_role_bootstrap(map(), String.t() | nil, URI.t()) :: {:ok, map()}
  def try_role_bootstrap(tmpl, config_dir, %URI{} = agent_uri) do
    case apply_orchestrator_role_bootstrap(tmpl, config_dir) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: orchestrator role-bootstrap failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)} — " <>
            "the agent will spawn as a plain cc agent (best-effort UX, " <>
            "SPEC 2026-05-26-session-create-orchestrator-unified Gap B); " <>
            "caller MUST surface the degraded status to the owner."
        )

        :telemetry.execute(
          [:ezagent, :cc, :role_bootstrap, :failed],
          %{count: 1},
          %{agent_uri: agent_uri, reason: reason, config_dir: config_dir}
        )

        {:ok,
         %{
           role_degraded: true,
           role_degraded_reason: reason
         }}
    end
  end

  @doc false
  @spec orchestrator_role?(map()) :: boolean()
  def orchestrator_role?(tmpl) when is_map(tmpl) do
    # codex PR #408 review LOW — accept both string and atom forms so
    # an atom-literal call site (`%{"role" => :orchestrator}`) reads the
    # same as the canonical string form (`%{"role" => "orchestrator"}`).
    # On-disk / snapshot-roundtripped templates carry the string; this
    # check is generous on ingress.
    case Map.get(tmpl, "role") do
      "orchestrator" -> true
      :orchestrator -> true
      _ -> false
    end
  end

  def orchestrator_role?(_), do: false

  # Resolve the on-disk source of the `ezagent-session-orchestrator`
  # skill. Defaults to walking upward from this plugin's priv_dir looking
  # for the first ancestor that contains
  # `.claude/skills/ezagent-session-orchestrator/SKILL.md`. Override via
  # `config :ezagent_plugin_cc, :orchestrator_skill_source, "/abs/path"`
  # — used by tests to point at a temp fixture without touching the real
  # umbrella file.
  #
  # codex PR #408 review HIGH-2 — pre-fix used `Path.expand("../../../..", priv)`
  # which is 4 segments and lands at `<repo>/_build/.claude/...` (off by
  # one — the test env masked it via the app-env override). A hardcoded
  # `..` count is brittle and silently breaks when the priv-path depth
  # changes (e.g. release builds nest differently). The walk searches for
  # the actual `.claude/skills/...` marker so it is robust to depth
  # changes, and explicitly returns the list of attempted paths on
  # failure so operators can diagnose a missing-skill deployment.
  @doc false
  @spec resolve_orchestrator_skill_source() :: {:ok, String.t()} | {:error, term()}
  def resolve_orchestrator_skill_source do
    override = Application.get_env(:ezagent_plugin_cc, :orchestrator_skill_source)

    cond do
      is_binary(override) and override != "" ->
        if File.dir?(override) do
          {:ok, override}
        else
          {:error, {:skill_source_missing, override}}
        end

      true ->
        search_orchestrator_skill_source()
    end
  end

  @orchestrator_skill_relpath ".claude/skills/ezagent-session-orchestrator"
  @orchestrator_skill_marker_relpath "SKILL.md"

  # Walk upward from this plugin's priv_dir, searching for the first
  # ancestor that holds `.claude/skills/ezagent-session-orchestrator/SKILL.md`.
  # Returns `{:ok, abs_skill_dir}` or `{:error, {:skill_source_not_found,
  # attempted_paths}}` so the operator can see which dirs were probed.
  defp search_orchestrator_skill_source do
    case :code.priv_dir(:ezagent_plugin_cc) do
      priv when is_list(priv) ->
        start = Path.expand(to_string(priv))
        search_orchestrator_skill_source_from(start)

      _ ->
        # Plugin not loaded — should be unreachable from a running
        # template, but guard anyway.
        {:error, {:skill_source_not_found, []}}
    end
  end

  @doc """
  Walk upward from `start_dir`, searching for the first ancestor that
  holds `.claude/skills/ezagent-session-orchestrator/SKILL.md`.

  Public (`@doc false`) so tests can force the exhausted-walk branch
  without monkey-patching `:code.priv_dir/1`. Production callers use
  `resolve_orchestrator_skill_source/0` which threads in the plugin's
  real priv-dir.

  Returns `{:ok, abs_skill_dir}` when found, or
  `{:error, {:skill_source_not_found, attempted_paths}}` on exhaust
  (parent == self at filesystem root).

  codex PR #408 r2 WARN HIGH-2 — the post-r1 walk-fallback's
  `:skill_source_not_found` tag was structurally reachable only via
  `:code.priv_dir` returning a non-list (unreachable from a loaded
  plugin). Extracting this public-for-test helper lets the
  exhausted-walk path be exercised directly.
  """
  @doc false
  @spec search_orchestrator_skill_source_from(String.t()) ::
          {:ok, String.t()} | {:error, {:skill_source_not_found, [String.t()]}}
  def search_orchestrator_skill_source_from(start_dir) when is_binary(start_dir) do
    walk_for_skill(start_dir, [])
  end

  # Bound the walk at the filesystem root. `Path.dirname/1` of `/` is `/`
  # on POSIX, so a parent-equals-self check is the loop termination.
  defp walk_for_skill(dir, attempted) do
    candidate = Path.join(dir, @orchestrator_skill_relpath)
    marker = Path.join(candidate, @orchestrator_skill_marker_relpath)
    attempted = [candidate | attempted]

    cond do
      File.regular?(marker) ->
        {:ok, candidate}

      true ->
        parent = Path.dirname(dir)

        if parent == dir do
          {:error, {:skill_source_not_found, Enum.reverse(attempted)}}
        else
          walk_for_skill(parent, attempted)
        end
    end
  end

  # Copy the skill tree into `<config_dir>/skills/ezagent-session-orchestrator/`.
  # Idempotent: when the destination dir already exists, return `:ok`
  # without re-copying. Per the SPEC's "Idempotence" rule, a re-spawn
  # MUST NOT re-copy the skill.
  defp copy_orchestrator_skill(source_dir, config_dir) do
    skills_root = Path.join(config_dir, "skills")
    dest_dir = Path.join(skills_root, "ezagent-session-orchestrator")

    cond do
      File.dir?(dest_dir) ->
        :ok

      true ->
        with :ok <- File.mkdir_p(skills_root),
             {:ok, _} <- File.cp_r(source_dir, dest_dir) do
          :ok
        else
          {:error, reason} -> {:error, {:skill_copy_failed, reason}}
          err -> {:error, {:skill_copy_failed, err}}
        end
    end
  end

  @orchestrator_hint_line "## Use the ezagent-session-orchestrator skill for all session coordination work."

  # Append the orchestrator-skill hint to `<config_dir>/CLAUDE.md`,
  # creating the file if missing. Idempotent: greps for the marker
  # line first; only appends when absent.
  defp append_orchestrator_claude_md_hint(config_dir) do
    claude_md = Path.join(config_dir, "CLAUDE.md")

    existing =
      case File.read(claude_md) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
        {:error, reason} -> {:error, reason}
      end

    case existing do
      {:error, reason} ->
        {:error, {:claude_md_hint_failed, reason}}

      content when is_binary(content) ->
        if String.contains?(content, @orchestrator_hint_line) do
          :ok
        else
          new_content =
            if content == "" or String.ends_with?(content, "\n") do
              content <> @orchestrator_hint_line <> "\n"
            else
              content <> "\n" <> @orchestrator_hint_line <> "\n"
            end

          case File.write(claude_md, new_content) do
            :ok -> :ok
            {:error, reason} -> {:error, {:claude_md_hint_failed, reason}}
          end
        end
    end
  end

  @doc """
  The CLAUDE.md hint line appended for orchestrator-role cc agents.
  Public so tests can assert exact content (SPEC Gap B B2 / B4).
  """
  @spec orchestrator_hint_line() :: String.t()
  def orchestrator_hint_line, do: @orchestrator_hint_line

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
    build_pty_params_for_env(agent_uri, cwd, tmpl, @compile_env)
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
  # shell command. The universal `config_dir` is returned as a structured env
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
      # "claude"); the rest is the hardening's safe arg assembly.
      #
      # 2026-06-01 — headless startup-dialog fix (verified via tmux +
      # live orchestrator round-trip; see
      # [[project_cc_channel_reply_unverified]]).
      #
      # `--permission-mode bypassPermissions` shows a "Bypass Permissions
      # mode … Yes, I accept" CONFIRMATION dialog at startup that a
      # headless PTY can't answer → claude parks pre-REPL → never loads
      # the esr-bridge channel → inbound `notifications/claude/channel`
      # are SILENTLY DROPPED (per the channels-reference) → the agent
      # receives mentions but never replies. Critically this dialog
      # appears BEFORE the `--dangerously-load-development-channels`
      # prompt, so the PtyServer auto-prompt scanner
      # (`default_auto_prompts/0`, which already answers the dev-channels
      # dialog with "1\r") never saw its trigger text.
      #
      # `--dangerously-skip-permissions` runs in the SAME bypass mode
      # WITHOUT that confirmation (verified: REPL still reports "bypass
      # permissions on"; the `--settings` safety file is unchanged). With
      # the bypass dialog gone, claude reaches the dev-channels prompt,
      # which the EXISTING PtyServer scanner auto-confirms — the channel
      # loads and the agent replies. No extra dialog-clearing code here.
      argv =
        [
          claude_path,
          "--dangerously-skip-permissions",
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
      cmd_env =
        base_env
        |> build_claude_config_env(tmpl)
        |> maybe_put_orchestrator_role_env(tmpl)

      {:ok, {argv, cmd_env}}
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap B —
  # when role is `"orchestrator"`, surface it to the claude process
  # via `EZAGENT_AGENT_ROLE`. The MCP bridge subprocesses claude
  # spawns inherit env from claude, so the orchestrator-MCP server
  # gets the same signal.
  defp maybe_put_orchestrator_role_env(env, tmpl) when is_map(env) do
    if orchestrator_role?(tmpl) do
      Map.put(env, "EZAGENT_AGENT_ROLE", "orchestrator")
    else
      env
    end
  end

  # Strict precedence — codex PR3 round-1 MEDIUM-1.
  # 1. valid `agent_config_dir` → use it
  # 2. invalid `agent_config_dir` (present but not valid binary) AND the
  #    universal `config_dir` also present → RAISE (would silently leak
  #    cross-agent credentials via shared ref dir)
  # 3. no `agent_config_dir` + valid universal `config_dir` → use it (legacy)
  # 4. neither valid → no CLAUDE_CONFIG_DIR (claude uses ~/.claude)
  #
  # config_dir promotion (Allen 2026-06-03): the template's reference
  # config-home arrives under the UNIVERSAL, flavor-neutral `"config_dir"`
  # data key (was `"claude_config_dir"`). This is the cc translation step:
  # cc reads the universal key and maps it to `CLAUDE_CONFIG_DIR`.
  defp build_claude_config_env(base_env, tmpl) do
    # codex P2 closure — fail loud on a STALE `"claude_config_dir"` data key.
    # `Workspace.Loader.invoke_template/2` calls `instantiate/3` directly
    # WITHOUT running `validate/1`, so a workspace-scoped / persisted template
    # carrying the old key would bypass the validator-level stale-key check
    # and silently spawn without `CLAUDE_CONFIG_DIR`. This is the PTY-env
    # chokepoint on BOTH the fresh and respawn paths (build_claude_cmd/3).
    reject_stale_config_dir_data_key!(tmpl)

    agent_dir = Map.get(tmpl, "agent_config_dir")
    template_dir = Map.get(tmpl, "config_dir")

    cond do
      valid_dir?(agent_dir) ->
        Map.put(base_env, "CLAUDE_CONFIG_DIR", agent_dir)

      # codex P2 closure — a PRESENT-but-malformed `"config_dir"` (`""` /
      # non-binary) must FAIL LOUD rather than silently fall through to no
      # `CLAUDE_CONFIG_DIR` (which would put the agent on the operator home).
      # An ABSENT key is the only legitimate "no config home". Mirrors
      # `create_agent_config_dir/2`. (Reached only when agent_dir is invalid;
      # a valid agent_dir already won the first branch.)
      config_dir_present_but_malformed?(tmpl) ->
        raise ArgumentError,
              "cc.agent: invalid config_dir #{inspect(template_dir)} — must be a " <>
                "non-empty string (or absent for no config home). No silent fallback " <>
                "to the operator home (feedback_let_it_crash_no_workarounds)."

      not is_nil(agent_dir) and valid_dir?(template_dir) ->
        raise ArgumentError,
              "cc.agent: invalid agent_config_dir #{inspect(agent_dir)} but the " <>
                "universal config_dir is also present — refusing to fall back to " <>
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

  # `"config_dir"` key is PRESENT but not a valid dir (`""` / non-binary /
  # `nil`-value). An absent key is NOT malformed (legitimate "no config home").
  defp config_dir_present_but_malformed?(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> false
      {:ok, v} -> not valid_dir?(v)
    end
  end

  # config_dir promotion (Allen 2026-06-03) — FAIL LOUD on a stale
  # `"claude_config_dir"` data key (codex P2 closure). Used by the cc consume
  # path (`create_agent_config_dir/2`, `build_claude_config_env/2`), which is
  # reached on the loader/boot path that bypasses `validate/1`. The per-agent
  # config-home is the universal, flavor-neutral `"config_dir"` key; the
  # cc-named key is NO LONGER part of the contract. A template still carrying
  # it would otherwise be silently dropped → the agent spawns without its
  # isolated config dir / `CLAUDE_CONFIG_DIR`. No back-compat shim
  # (`feedback_let_it_crash_no_workarounds`) — raise so the misconfiguration
  # is visible.
  defp reject_stale_config_dir_data_key!(tmpl) when is_map(tmpl) do
    if Map.has_key?(tmpl, "claude_config_dir") do
      raise ArgumentError,
            "cc.agent: stale `claude_config_dir` data key — config_dir is now the " <>
              "universal, flavor-neutral `config_dir` key (Allen 2026-06-03). Rename " <>
              "`claude_config_dir` → `config_dir`. No back-compat shim " <>
              "(feedback_let_it_crash_no_workarounds)."
    else
      :ok
    end
  end

  defp reject_stale_config_dir_data_key!(_), do: :ok

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
  # agent gets its OWN config dir (copied from the template`s reference
  # universal `config_dir` at spawn). The dir is the per-agent CLAUDE_CONFIG_DIR
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

                # 2026-05-31 orchestrator-startup-atomicity §5 — for an
                # ORCHESTRATOR boot respawn, readiness = REGISTERED, not
                # process-alive. Await the same live-join gate (staggered
                # so N orchestrators don't each block 30s simultaneously);
                # on timeout fail-loud (returns `{:error, _}` → Sandbox
                # logs + telemetry `:subprocess_unhealthy` + stops the
                # respawn — the operator restarts via /admin). Test-mode
                # skips the live wait (no real claude to JOIN). A non-
                # orchestrator cc agent has no registration gate (out of
                # scope per SPEC §10) → `:ok` immediately.
                await_orchestrator_boot_readiness(agent_uri, respawn_data)

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

  # 2026-05-31 orchestrator-startup-atomicity §5 — orchestrator boot
  # readiness gate. Mirrors `Session.ensure_orchestrator/3`'s create-time
  # gate, on the BOOT respawn path: a respawned orchestrator PTY is only
  # READY once its live claude's MCP bridge JOINs + registers (broadcast
  # on `"orch:lifecycle"`). Until then it is a non-functional zombie that
  # would retry the bridge JOIN forever.
  #
  # Bounded-concurrency STAGGER: on a multi-orchestrator boot, having
  # every Kind's `activate/2` block 30s simultaneously is an N×30s boot
  # storm. We serialize the WAITS through `@orch_boot_gate_slots`
  # `:global.trans` lock slots (slot = `phash2(uri) rem N`) so at most N
  # gates wait concurrently; the rest queue behind a slot.
  @orchestrator_boot_readiness_timeout_ms 30_000
  @orch_boot_gate_slots 4

  defp await_orchestrator_boot_readiness(%URI{} = agent_uri, respawn_data) do
    cond do
      not orchestrator_role?(respawn_data) ->
        # Non-orchestrator cc agent — no registration gate (SPEC §10 out).
        :ok

      orchestrator_gate_test_mode?() ->
        # No live claude in test_mode → no bridge JOIN → the gate would
        # always time out. The synchronous registration is the test's
        # readiness; skip the live wait.
        :ok

      true ->
        with_orch_boot_gate_slot(agent_uri, fn ->
          do_await_orchestrator_boot_readiness(agent_uri)
        end)
    end
  end

  # Run `fun` while holding one of N global gate slots — bounds the number
  # of concurrent 30s waits across all booting orchestrators. `:global.trans`
  # blocks until the slot lock is acquired (FIFO-ish), then releases it
  # when `fun` returns.
  defp with_orch_boot_gate_slot(%URI{} = agent_uri, fun) when is_function(fun, 0) do
    slot = :erlang.phash2(URI.to_string(agent_uri), @orch_boot_gate_slots)
    lock_id = {{:ezagent_orch_boot_gate, slot}, self()}
    :global.trans(lock_id, fun)
  end

  # Subscribe-then-check-then-wait. We subscribe to `"orch:lifecycle"`
  # FIRST, then check whether the orchestrator is ALREADY registered
  # (the bridge may have joined during the PTY respawn / slot wait); if so
  # we are done. Otherwise `receive` the readiness signal ≤30s. On timeout
  # fail-loud.
  defp do_await_orchestrator_boot_readiness(%URI{} = agent_uri) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, orch_lifecycle_topic())

    if orchestrator_registered?(agent_uri) do
      _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())
      :ok
    else
      receive_orchestrator_boot_ready(agent_uri)
    end
  end

  defp receive_orchestrator_boot_ready(%URI{} = agent_uri) do
    receive do
      {:orchestrator_ready, %URI{} = ready_uri} ->
        if URI.to_string(ready_uri) == URI.to_string(agent_uri) do
          _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())
          :ok
        else
          receive_orchestrator_boot_ready(agent_uri)
        end
    after
      @orchestrator_boot_readiness_timeout_ms ->
        _ = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, orch_lifecycle_topic())

        Logger.error(
          "cc.agent.ensure_subprocess_alive: orchestrator #{URI.to_string(agent_uri)} did " <>
            "NOT register within #{@orchestrator_boot_readiness_timeout_ms}ms on boot respawn " <>
            "— failing loud (Sandbox stops the respawn; operator restarts via /admin)."
        )

        {:error, {:orchestrator_not_ready_within, @orchestrator_boot_readiness_timeout_ms}}
    end
  end

  # The lifecycle topic string. Hard-coded here (NOT a call into
  # `Ezagent.Orchestrator.McpChannel.lifecycle_topic/0`) because
  # `ezagent_domain_chat` is a `only: :test` dep of this plugin — it is
  # NOT a compile dep in prod. The topic is a stable string contract
  # shared with `McpChannel.join/3`'s broadcast (§5); a drift would be
  # caught by the live e2e (the only validator of the live gate).
  defp orch_lifecycle_topic, do: "orch:lifecycle"

  # Registered? = `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1`
  # resolves. Runtime-guarded `apply` (NOT a direct module ref) for the
  # same `only: :test` dep reason as `orch_lifecycle_topic/0`: the module
  # IS loaded at runtime (chat boots in the umbrella) but referencing it
  # at compile time would break this plugin's prod build. A not-loaded
  # module (impossible in the running umbrella, but defensive) → not
  # registered → fall through to the live wait.
  defp orchestrator_registered?(%URI{} = agent_uri) do
    mod = Ezagent.Orchestrator.McpServer

    if Code.ensure_loaded?(mod) and function_exported?(mod, :from_orchestrator_uri, 1) do
      match?({:ok, _}, apply(mod, :from_orchestrator_uri, [agent_uri]))
    else
      false
    end
  end

  # test_mode = compile-time `:test` — same rationale as the create-time
  # gate (cc PtyServer short-circuits real claude in `:test`). Compile-time
  # attr (not runtime Mix.env()) for release-safety. (codex final-review Q1.)
  defp orchestrator_gate_test_mode?, do: @compile_env == :test

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
  # template's universal `config_dir` field (now interpreted as
  # "reference" — not the dir the process actually uses).
  #
  # config_dir promotion (Allen 2026-06-03): the reference config-home
  # arrives under the UNIVERSAL, flavor-neutral `"config_dir"` data key
  # (was `"claude_config_dir"`); cc reads it here as its claude reference
  # dir to copy per-agent.
  #
  # Returns `{:ok, path}` where path is the absolute per-agent dir.
  # If no reference dir is configured on the template, returns
  # `{:ok, nil}` — agent runs without `CLAUDE_CONFIG_DIR` (legacy
  # behavior, valid for agents that need no sandbox).
  @doc false
  @spec create_agent_config_dir(URI.t(), map()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def create_agent_config_dir(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    # codex P2 closure — fail loud on a stale `"claude_config_dir"` data key
    # (the loader path bypasses `validate/1`). See
    # `reject_stale_config_dir_data_key!/1`.
    reject_stale_config_dir_data_key!(tmpl)

    # codex P2 closure — distinguish ABSENT/nil (legitimate: no config home)
    # from PRESENT-but-malformed (`""` / non-binary → FAIL LOUD). The loader
    # path bypasses `validate/1`, so a malformed `"config_dir"` must be
    # rejected here rather than silently treated as absent (which would spawn
    # without `CLAUDE_CONFIG_DIR`, falling back to the operator home). Use
    # `Map.fetch/2` so a present `nil` is also rejected as malformed (an
    # absent key is the only legitimate "no config home").
    case Map.fetch(tmpl, "config_dir") do
      :error ->
        # Key absent — the agent runs without a config home (legacy: claude
        # reads from `~/.claude`). The Sandbox slice's config_dir_path is nil.
        {:ok, nil}

      {:ok, ref} when is_binary(ref) and ref != "" ->
        do_create_agent_config_dir(agent_uri, ref)

      {:ok, bad} ->
        {:error, {:invalid_config_dir, bad}}
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
