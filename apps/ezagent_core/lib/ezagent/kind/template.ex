defmodule Ezagent.Kind.Template do
  @moduledoc """
  Template Class behaviour — the Class half of Decision #64's double
  Template model (Class + Instance).

  ## Position in the model

  - **Template Instance** (already shipped Phase 4b/c) — a Workspace
    Kind carrying `session_templates` map in state.
  - **Template Class** (this behaviour) — plugin-author module that
    knows how to validate template data and instantiate Kinds from it.

  A Workspace's `session_templates` entry references a Class by name
  (`"class"` field in the template data); `Ezagent.TemplateRegistry` maps
  name → module; `Ezagent.Workspace.Loader` dispatches `instantiate/3` at
  app start to bring the declared Kinds to life.

  This is the **runtime DI form** for plugin authors to add new
  spawnable shapes without touching ezagent_core — parallel to
  `Ezagent.SpawnRegistry` (one-Kind-per-URI-scheme) but for whole
  composable structures (Session + members + routing).

  ## Callbacks

  - `template_name/0` — stable string id (e.g. `"session.generic"`).
    Stored in the Workspace's `session_templates` map as the `"class"`
    field. Per Decision #62 (snapshot-safe stable IDs).
  - `validate/1` — pure shape check called by
    `Ezagent.Workspace.add_template/3` BEFORE persisting. Fail-fast.
    Optional callback — default `:ok`.
  - `instantiate/3` — effectful. Called by `Ezagent.Workspace.Loader` at
    boot and by `add_template/3` after persist. **Must be idempotent**:
    re-calling after the spawned Kinds are alive should be a no-op,
    returning the same URIs (`SpawnRegistry.spawn/1` provides this for
    the common case).

  ## Return shape of `instantiate/3`

  `{:ok, [URI.t()]}` — list of URIs the Class spawned. Loader records
  these for telemetry / observability. Returning a list (not a single
  URI) lets a Class spawn multiple Kinds in one call (e.g. Session +
  N Agents + connections).

  `{:ok, [URI.t()], meta}` — the SAME, plus a `meta` map carrying
  per-instantiate signals (codex round-6 HIGH-1). The one signal in
  use today is `%{fresh?: boolean()}` — `true` iff THIS call's
  `DynamicSupervisor.start_child` started the worker (vs adopting a
  pre-existing one). `update_agent_template`'s rollback-safe swap
  reads `fresh?` to refuse silently adopting a worker another process
  created. A Class that does not produce the signal returns the
  2-element form; consumers treat an absent `fresh?` conservatively as
  `false`. The 2- and 3-element forms are BOTH valid — `Loader`
  accepts either.
  """

  @type template_data :: map()
  @type template_name :: String.t()
  @type instantiate_meta :: %{optional(:fresh?) => boolean()}

  @callback template_name() :: template_name()
  @callback validate(template_data()) :: :ok | {:error, term()}
  @callback instantiate(template_name(), template_data(), workspace_uri :: URI.t()) ::
              {:ok, [URI.t()]}
              | {:ok, [URI.t()], instantiate_meta()}
              | {:error, term()}

  # --- flavor-specific template_data fields (SPEC 2026-06-01 approach B) -
  #
  # `Ezagent.Entity.AgentTemplate.to_template_data/2` builds the universal
  # base (`class` / `agent_uri` / `cwd`) and then MERGES this callback's
  # result for the flavor-specific fields the flavor's `instantiate/3`
  # reads. This keeps core flavor-agnostic — cc's `claude_config_dir`,
  # curl's `provider`/`api_url`/`model`, codex's `model`/`sandbox`/… are
  # each owned by the respective plugin, NOT hardcoded in
  # `ezagent_domain_chat`.
  #
  # Contract:
  # - Read from `content` (the AgentTemplate `:template` slice), which may
  #   carry ATOM or STRING keys (atom when freshly built, string after a
  #   JSON snapshot round-trip).
  # - Return a map with STRING keys (the `instantiate/3`/`validate/1`
  #   contract reads string keys). nil values are dropped by the caller;
  #   the reserved keys `class`/`agent_uri`/`cwd` are ignored if returned.
  # - Omit optional fields that are not present / not non-empty binaries
  #   (e.g. codex `bridge_ws_url`/`codex_path` feed runtime paths).
  #
  # Optional: a flavor without this callback contributes no extras (base
  # only). `to_template_data/2` then runs the flavor's `validate/1` on the
  # merged data, so a flavor template MISSING a required field fails LOUD
  # (`{:error, {:invalid_template_data, _}}`) instead of spawning a
  # nil-config worker.
  @callback template_data_extra(content :: map()) :: %{optional(String.t()) => term()}

  # --- per-agent extension management (PR2 2026-05-24, codex round-1) ---
  #
  # Allen 2026-05-24 architectural decision: every spawned agent gets
  # its OWN config dir; the plugin Template Class owns the contract for
  # enumerating, mutating, and destroying that dir. Core knows NOTHING
  # about what lives in it (skills, plugins, MCP configs — that's
  # plugin terminology).
  #
  # **NOTE on `create_config_dir`** (codex PR2 round-1 HIGH-1): there is
  # NO `create_config_dir/N` callback by design. The 2-phase pattern
  # ("init slice nil → late dispatch write_path") was too late for
  # plugins that launch a sidecar during `instantiate/3` using a
  # filesystem path (cc starts its PTY with `claude_config_dir` before
  # any subsequent dispatch could populate the slice). Instead, the
  # plugin's `instantiate/3` is the one that creates the per-agent dir
  # (it is the only place that knows the full plugin-specific spawn
  # timing) and returns the path through the existing
  # `instantiate_meta()` shape — `Agent.spawn_from_template_content/4`
  # then dispatches `sandbox.write_path` AFTER the plugin's instantiate
  # succeeds. PR3 lands the meta-passing convention + cc plugin impl.
  #
  # The other 3 callbacks below ARE here because they are POST-create
  # operations that the LV / destroy verb invoke against a known
  # `config_dir_path` (read from the agent's `:sandbox` slice).
  #
  # All three callbacks are `@optional_callbacks` so existing Template
  # Classes (echo, curl, np, generic_session) need NO change. **A Class
  # that opts in MUST implement ALL THREE** (codex PR2 round-1 MEDIUM-3
  # — partial opt-in leaks filesystem on destroy). The
  # `Ezagent.Invariants.TemplateClassExtensionContractTest` invariant
  # gates this at test time.
  #
  # "extension" is plugin-neutral terminology — cc plugin implements it
  # as Claude Code "plugins" (Anthropic's term: bundles containing
  # skills + agents + commands + MCP servers + hooks under
  # `.claude/plugins/`); a future Codex plugin could implement it as
  # prompt snippets; a Curl plugin could implement it as endpoint specs.

  @type config_dir_path :: String.t()
  @type extension_id :: String.t()
  @type extension :: %{
          required(:id) => extension_id(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:enabled?) => boolean()
        }
  @type agent_uri :: URI.t()

  @doc """
  Enumerate the extensions available in `config_dir` with their current
  enabled-state. Called by the plugin-agnostic
  `/admin/agents/:uri/extensions` LV to render the toggle grid.

  Returns `{:ok, [extension]}` — a flat list of extension descriptors.
  Order is implementation-defined (LV sorts as needed).
  """
  @callback list_extensions(config_dir_path()) :: {:ok, [extension()]} | {:error, term()}

  @doc """
  Toggle `extension_id` on (`enabled? = true`) or off in `config_dir`.
  Called by the LV when the operator clicks a checkbox.

  Implementations mutate the config dir's filesystem (install or
  uninstall the extension bundle, write `.claude/settings.json`, etc.).
  Idempotent: re-toggling to the same state is `:ok`.
  """
  @callback toggle_extension(config_dir_path(), extension_id(), enabled? :: boolean()) ::
              :ok | {:error, term()}

  @doc """
  Destroy the per-agent config dir at `config_dir_path`.

  **Signature note (codex PR2 round-1 MEDIUM-3):** receives BOTH
  `agent_uri` AND `config_dir_path` — the plugin does NOT have to
  reverse-engineer the path from the URI (which would break for
  non-deterministic paths or restored-from-snapshot agents). The path
  the plugin's `instantiate/3` originally returned in meta is exactly
  what `Sandbox.invoke(:destroy, ...)` reads from the slice and passes
  back here.

  Called by `Sandbox.invoke(:destroy, ...)` on agent teardown.
  Best-effort — failure does NOT block the Agent process termination
  but is logged.
  """
  @callback destroy_config_dir(agent_uri(), config_dir_path()) :: :ok | {:error, term()}

  @doc """
  PTY-orphan-restart 2026-05-26 — re-spawn the plugin-owned subprocess
  for `agent_uri` if it's not already alive, using `respawn_data` (the
  same opaque map the plugin's `instantiate/3` consumed at original
  spawn).

  Invoked by `Ezagent.Behavior.Sandbox`'s `post_init/2` continuation
  AFTER the Agent Kind has been rehydrated from snapshot on phx
  restart. The hook closes the gap where the Elixir Kind survives a
  restart (OTP-supervised) but the OS-level subprocess does NOT
  (claude / Python is a port-managed child that dies with the BEAM,
  or worse survives as an orphan on brutal kill).

  ## Contract

  - **Idempotent**: a call when the subprocess is already alive
    returns `:ok` immediately (no double-start).
  - **Self-contained**: do NOT re-walk Workspace.Store or any other
    domain registry — `respawn_data` is the persisted, snapshot-
    backed copy of `instantiate/3`'s tmpl arg. If the operator
    changed the workspace template between the original spawn and
    this restart, the snapshot reflects the OLD config; next
    operator-initiated re-instantiate picks up the new one.
  - **Let-it-crash on `{:error, _}`**: Sandbox.handle_continue/3
    re-raises so Kind.Server's supervisor restarts the Kind with
    backoff. Don't try to recover internally — the supervisor's
    retry handles transient races (e.g. orphan-reaper still
    running).
  - **Optional**: plugins whose Template Class manages a per-agent
    subprocess (cc, np) MUST implement; plugins that don't (echo,
    curl) skip — the callback isn't called when not exported.

  ## Args

  - `agent_uri` — the Agent Kind's URI (canonical
    `entity://agent/<workspace>/<flavor>_<name>`).
  - `respawn_data` — the opaque map the plugin's `instantiate/3`
    consumed at original spawn (cc carries cwd + the sandbox keys;
    np carries cwd + timeout_ms). Persisted in
    `:sandbox.respawn_template_data`.

  ## Return

  `:ok` on success (subprocess alive, either pre-existing or newly
  started). `{:error, reason}` to trigger a supervisor restart of
  the Agent Kind.
  """
  @callback ensure_subprocess_alive(agent_uri(), respawn_data :: map()) ::
              :ok | {:error, term()}

  @optional_callbacks [
    validate: 1,
    template_data_extra: 1,
    list_extensions: 1,
    toggle_extension: 3,
    destroy_config_dir: 2,
    ensure_subprocess_alive: 2
  ]
end
