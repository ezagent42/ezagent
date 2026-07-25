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
  @type resolved_manifest :: map()
  @type config_field_type ::
          :string | :text | :integer | :boolean | :enum | :list | :json | :secret
  @type config_field :: %{
          required(:key) => String.t(),
          required(:type) => config_field_type(),
          required(:label) => String.t(),
          optional(:options) => [String.t()],
          optional(:default) => term(),
          optional(:required) => boolean(),
          optional(:help) => String.t()
        }

  @callback template_name() :: template_name()
  @callback validate(template_data()) :: :ok | {:error, term()}

  @doc """
  Compile a resolved `Ezagent.AgentManifest` plus executor params into
  flavor-specific template data.

  This is the pure, flavor-owned seam for authored agent definitions. Core
  builds only the universal template base (`class` / `agent_uri` / `cwd` /
  `config_dir`) and then validates the merged data through `validate/1`.
  """
  @callback compile(resolved_manifest(), params :: map()) ::
              {:ok, template_data()} | {:error, term()}

  @callback instantiate(template_name(), template_data(), workspace_uri :: URI.t()) ::
              {:ok, [URI.t()]}
              | {:ok, [URI.t()], instantiate_meta()}
              | {:error, term()}

  @callback instantiate(template_name(), template_data(), URI.t(), keyword()) ::
              {:ok, [URI.t()]}
              | {:ok, [URI.t()], instantiate_meta()}
              | {:error, term()}

  @doc """
  Declares whether this Template Class can be instantiated directly from the
  generic "New session" picker — i.e. whether `instantiate/3` succeeds given
  ONLY the universal create args the generic picker supplies (`class` +
  `session_name`).

  Default `true`. A Class whose `instantiate/3` requires EXTRA, picker-unknown
  arguments (e.g. a vertical session class that needs an `operator_uri`)
  overrides this to
  `false` so the generic picker never offers it as a creatable option — picking
  it would otherwise fail closed with `{:error, {:invalid_template, …}}`
  (the F3 silent-create bug). Such Classes are still instantiable through their
  own vertical's create path that supplies the extra args.

  Optional callback — a Class that omits it is treated as directly creatable
  (`directly_creatable?/1` below applies the default).
  """
  @callback directly_creatable?() :: boolean()

  # --- flavor-specific template_data fields (SPEC 2026-06-01 approach B) -
  #
  # `Ezagent.Entity.AgentTemplate.to_template_data/2` builds the universal
  # base (`class` / `agent_uri` / `cwd` / `config_dir`) and then MERGES this
  # callback's result for the flavor-specific fields the flavor's
  # `instantiate/3` reads. This keeps core flavor-agnostic — the per-agent
  # config-home dir is UNIVERSAL (the neutral `config_dir` key; config_dir
  # promotion, Allen 2026-06-03), and the FLAVOR-specific extras — cc's
  # `operator_settings_path`/`role`, curl's `provider`/`api_url`/`model`,
  # codex's `model`/`sandbox`/… — are each owned by the respective plugin,
  # NOT hardcoded in `ezagent_domain_session`. cc READS the universal
  # `config_dir` and applies its claude semantics (CLAUDE_CONFIG_DIR).
  #
  # Contract:
  # - Read from `content` (the AgentTemplate `:template` slice), which may
  #   carry ATOM or STRING keys (atom when freshly built, string after a
  #   JSON snapshot round-trip).
  # - Return a map with STRING keys (the `instantiate/3`/`validate/1`
  #   contract reads string keys). nil values are dropped by the caller;
  #   the reserved keys `class`/`agent_uri`/`cwd`/`config_dir` are ignored
  #   if returned.
  # - Omit optional fields that are not present / not non-empty binaries
  #   (e.g. codex `bridge_ws_url`/`codex_path` feed runtime paths).
  #
  # Optional: a flavor without this callback contributes no extras (base
  # only). `to_template_data/2` then runs the flavor's `validate/1` on the
  # merged data, so a flavor template MISSING a required field fails LOUD
  # (`{:error, {:invalid_template_data, _}}`) instead of spawning a
  # nil-config worker.
  @callback template_data_extra(content :: map()) :: %{optional(String.t()) => term()}

  @doc """
  Describe operator-editable config fields for this Template Class.

  This is a UI shape contract only. The Template Class's `validate/1` remains
  the authoritative runtime validation boundary.
  """
  @callback config_schema() :: [config_field()]

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
  # ("init slice nil → late dispatch update_config") was too late for
  # plugins that launch a sidecar during `instantiate/3` using a
  # filesystem path (cc starts its PTY with the universal `config_dir` before
  # any subsequent dispatch could populate the slice). Instead, the
  # plugin's `instantiate/3` is the one that creates the per-agent dir
  # (it is the only place that knows the full plugin-specific spawn
  # timing) and returns the path through the existing
  # `instantiate_meta()` shape — `Agent.spawn_from_template_content/4`
  # then dispatches `sandbox.update_config` AFTER the plugin's instantiate
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

  Invoked by `Ezagent.ActionSet.Sandbox`'s `post_init/2` continuation
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

  @doc """
  PR-3 (domain.agent D2) — the config_dir path NAMESPACE for this flavor (e.g.
  `"cc"` → `Ezagent.Sandbox.ConfigDir` builds `<Home>/cc-agents/<ws>/<name>`).

  Optional: a flavor that omits it has its namespace derived from
  `template_name/0` by stripping a trailing `.agent` (see `namespace_of/1`). cc
  declares `"cc"` explicitly so the layout stays byte-identical to the pre-PR-3
  `cc-agents/...` (no migration).
  """
  @callback config_dir_namespace() :: String.t()

  @optional_callbacks [
    instantiate: 4,
    validate: 1,
    compile: 2,
    template_data_extra: 1,
    config_schema: 0,
    config_dir_namespace: 0,
    directly_creatable?: 0,
    list_extensions: 1,
    toggle_extension: 3,
    destroy_config_dir: 2,
    ensure_subprocess_alive: 2
  ]

  @doc """
  Resolve whether `class_module` is directly creatable from the generic
  session picker (the F3 declared-capability seam). Prefers the optional
  `directly_creatable?/0` callback; defaults to `true` when the Class omits it.

  Used by the world plugin's "New session" picker to offer only Classes whose
  `instantiate/3` succeeds with the universal create args.
  """
  @spec directly_creatable?(module()) :: boolean()
  def directly_creatable?(class_module) when is_atom(class_module) do
    if function_exported?(class_module, :directly_creatable?, 0) do
      class_module.directly_creatable?()
    else
      true
    end
  end

  @doc """
  Resolve the config_dir path namespace for a Template Class.

  Boot-safe: the class module is available at every `instantiate/3` call site
  (it is the receiver) AND on cold-restart, whereas `template_data` carries no
  flavor key. Prefers the optional `config_dir_namespace/0` callback; otherwise
  derives the namespace from `template_name/0` by stripping a trailing `.agent`.
  """
  @spec namespace_of(module()) :: String.t()
  def namespace_of(class_module) when is_atom(class_module) do
    if function_exported?(class_module, :config_dir_namespace, 0) do
      class_module.config_dir_namespace()
    else
      class_module.template_name()
      |> String.replace_suffix(".agent", "")
    end
  end

  @doc """
  PR-3 (domain.agent D2) — the single contract-boundary chokepoint for spawning a
  flavor: allocate the per-agent config_dir TARGET (when the template carries a
  `config_dir` reference) and provide it to the plugin as the `"allocated_config_dir"`
  data key, THEN delegate to `class_module.instantiate/3`. The plugin materializes
  content into the provided dir; it never chooses the path (North-Star isolation).

  EVERY `instantiate/3` caller (the domain spawn helper, the workspace Loader
  invoke + boot, the LV operator-create) routes through here, so the allocation is
  uniform across fresh-create / loader / boot seams. Returns whatever
  `instantiate/3` returns (the 2- or 3-element `{:ok, uris[, meta]}` / `{:error, _}`
  shape).

  Allocation is skipped when the template has no `config_dir` reference
  (curl/codex/echo/np ⇒ zero filesystem footprint). A reference WITHOUT an
  `"agent_uri"` fails loud — the target is undeterminable.
  """
  @spec provision_and_instantiate(module(), template_name(), template_data(), URI.t()) ::
          {:ok, [URI.t()]}
          | {:ok, [URI.t()], instantiate_meta()}
          | {:error, term()}
  def provision_and_instantiate(class_module, tmpl_name, tmpl_data, %URI{} = workspace_uri)
      when is_atom(class_module) and is_map(tmpl_data) do
    provision_and_instantiate(class_module, tmpl_name, tmpl_data, workspace_uri, [])
  end

  @doc false
  @spec provision_and_instantiate(
          module(),
          template_name(),
          template_data(),
          URI.t(),
          keyword()
        ) ::
          {:ok, [URI.t()]}
          | {:ok, [URI.t()], instantiate_meta()}
          | {:error, term()}
  def provision_and_instantiate(class_module, tmpl_name, tmpl_data, %URI{} = workspace_uri, opts)
      when is_atom(class_module) and is_map(tmpl_data) and is_list(opts) do
    with :ok <- validate_instantiate_callback(class_module, opts),
         {:ok, data} <- maybe_allocate_config_dir(class_module, tmpl_data) do
      result =
        case opts do
          [] ->
            class_module.instantiate(tmpl_name, data, workspace_uri)

          [launch_context: _context] ->
            class_module.instantiate(tmpl_name, data, workspace_uri, opts)
        end

      # Record the flavor ONLY for a genuinely fresh instance, AFTER instantiate
      # returns its fresh-vs-adopted signal — never before. Storing before
      # instantiate CLOBBERED an ADOPTED instance's original flavor: instantiate
      # can adopt a pre-existing worker (a concurrent spawn registered the URI
      # first) and return `{:ok, workers, %{fresh?: false}}` — an :ok path, so the
      # pre-store's flavor was never undone (undo only fired on `{:error, _}`).
      # Gate on fresh?: true (mirrors `Ezagent.Entity.Agent.TemplateSpawn` codex
      # round-7). The legacy 2-tuple return carries no adopt signal → fresh by
      # contract. `AttributeHook` is write-only (no reader), so deferring the store
      # past instantiate is safe. (#1570 regression; main-red #189.)
      case result do
        {:ok, _workers} = ok ->
          :ok = maybe_store_agent_flavor(class_module, data, opts)
          ok

        {:ok, _workers, %{fresh?: true}} = ok ->
          :ok = maybe_store_agent_flavor(class_module, data, opts)
          ok

        {:ok, _workers, _meta} = ok ->
          # Adopted a pre-existing instance (fresh?: false) or no fresh signal —
          # leave its original flavor untouched; do NOT store.
          ok

        {:error, _reason} = error ->
          # instantiate failed before any flavor store — nothing to undo.
          error
      end
    end
  end

  defp validate_instantiate_callback(_class_module, []), do: :ok

  defp validate_instantiate_callback(class_module, launch_context: _context) do
    with {:module, ^class_module} <- Code.ensure_loaded(class_module),
         true <- function_exported?(class_module, :instantiate, 4) do
      :ok
    else
      _reason -> {:error, :template_launch_context_not_supported}
    end
  end

  defp validate_instantiate_callback(_class_module, _opts),
    do: {:error, :invalid_launch_options}

  # Allocate the TARGET only when the template carries a config_dir REFERENCE
  # (the flavor wants a config home). The realized target rides in as
  # `"allocated_config_dir"`; the plugin copies the reference into it.
  defp maybe_allocate_config_dir(class_module, tmpl_data) do
    case Map.get(tmpl_data, "config_dir") do
      ref when is_binary(ref) and ref != "" ->
        with {:ok, agent_uri} <- fetch_agent_uri(tmpl_data),
             {:ok, target} <-
               Ezagent.Sandbox.ConfigDir.allocate(agent_uri, namespace_of(class_module)) do
          {:ok, Map.put(tmpl_data, "allocated_config_dir", target)}
        end

      _ ->
        {:ok, tmpl_data}
    end
  end

  defp fetch_agent_uri(tmpl_data) do
    case Map.get(tmpl_data, "agent_uri") do
      s when is_binary(s) and s != "" -> {:ok, Ezagent.URI.new!(s)}
      _ -> {:error, :config_dir_allocate_missing_agent_uri}
    end
  end

  defp maybe_store_agent_flavor(_class_module, _tmpl_data, launch_context: _context), do: :ok

  defp maybe_store_agent_flavor(class_module, tmpl_data, []) do
    case Map.get(tmpl_data, "agent_uri") do
      s when is_binary(s) and s != "" ->
        s
        |> Ezagent.URI.new!()
        |> Ezagent.Kind.Template.AttributeHook.store(class_module)

      _ ->
        :ok
    end
  end

  # --- shared Template-Class validation helpers (Cleanup-2 dedup) ----------
  #
  # These two helpers were copy-pasted, byte-identical, across every flavor
  # Template Class (cc / codex / curl / echo / np). They are pure functions
  # with no flavor-specific semantics, so they live here in core — the module
  # every flavor Template Class already `@behaviour`s — and each flavor
  # delegates. Placing the shared helper in core (not in one plugin imported
  # by the others) preserves plugin isolation: flavors depend on core, never
  # on a sibling plugin.

  @doc """
  Validate that a template's `"agent_uri"` is a well-formed entity-agent URI.

  PR-B unify-uri-query: the URI is an opaque identifier. This validator
  checks only the structural entity-agent shape; flavor is stored in the
  Template Class/content, never parsed from the URI name prefix.

  Returns `:ok`, or a tagged error:

  - `{:error, :missing_agent_uri}` — no non-empty `"agent_uri"` string.
  - `{:error, {:invalid_agent_uri, uri_str, reason}}` — parses to a URI
    that is not an `entity://` agent URI.
  - `{:error, {:bad_agent_uri, uri_str}}` — does not parse as a URI.
  """
  @spec check_agent_uri(map()) :: :ok | {:error, term()}
  def check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity"} = uri ->
          if Ezagent.URI.type?(uri, :agent) do
            :ok
          else
            {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}
          end

        %URI{} ->
          {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}

        _ ->
          {:error, {:bad_agent_uri, uri_str}}
      end
    rescue
      ArgumentError -> {:error, {:bad_agent_uri, uri_str}}
    end
  end

  def check_agent_uri(_), do: {:error, :missing_agent_uri}

  @doc """
  Read `key` from a Template Class `content` map tolerantly.

  AgentTemplate `content` may carry atom (fresh) or string (post-JSON)
  keys; this reads the atom key first, then falls back to the string form.
  """
  @spec content_field(map(), atom()) :: term()
  def content_field(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      v -> v
    end
  end

  @doc false
  @spec compile_curl_agent_data(map(), map(), (map() -> map())) ::
          {:ok, template_data()} | {:error, term()}
  def compile_curl_agent_data(resolved, params, template_data_extra)
      when is_map(resolved) and is_map(params) and is_function(template_data_extra, 1) do
    with :ok <- reject_required_tools(resolved, "curl") do
      content =
        params
        |> Map.put("system_prompt", content_field(resolved, :instructions))

      {:ok, compact_template_data(template_data_extra.(content))}
    end
  end

  def compile_curl_agent_data(_resolved, _params, _template_data_extra),
    do: {:error, :invalid_compile_args}

  @doc false
  @spec compile_cc_agent_data(map(), map(), (map() -> map())) ::
          {:ok, template_data()} | {:error, term()}
  def compile_cc_agent_data(resolved, params, template_data_extra)
      when is_map(resolved) and is_map(params) and is_function(template_data_extra, 1) do
    with {:ok, instructions} <- compile_manifest_instructions(resolved) do
      claude_md = "#{content_field(params, :claude_md_preamble) || ""}#{instructions}"

      data =
        params
        |> template_data_extra.()
        |> Map.put("claude_md", claude_md)
        |> put_manifest_tool_data(resolved)
        |> compact_template_data()

      {:ok, data}
    end
  end

  def compile_cc_agent_data(_resolved, _params, _template_data_extra),
    do: {:error, :invalid_compile_args}

  @doc false
  @spec compile_codex_agent_data(map(), map(), (map() -> map())) ::
          {:ok, template_data()} | {:error, term()}
  def compile_codex_agent_data(resolved, params, template_data_extra)
      when is_map(resolved) and is_map(params) and is_function(template_data_extra, 1) do
    with {:ok, instructions} <- compile_manifest_instructions(resolved) do
      data =
        params
        |> template_data_extra.()
        |> Map.put("instructions", instructions)
        |> put_manifest_tool_data(resolved)
        |> compact_template_data()

      {:ok, data}
    end
  end

  def compile_codex_agent_data(_resolved, _params, _template_data_extra),
    do: {:error, :invalid_compile_args}

  defp compile_manifest_instructions(resolved) do
    case content_field(resolved, :instructions) do
      instructions when is_binary(instructions) -> {:ok, instructions}
      other -> {:error, {:invalid_instructions, other}}
    end
  end

  defp put_manifest_tool_data(data, resolved) do
    case required_tools(resolved) do
      [] ->
        data

      tools ->
        data
        |> Map.put("manifest_tools", tools)
        |> Map.put("manifest_mcp_servers", manifest_mcp_servers(tools))
    end
  end

  defp reject_required_tools(resolved, flavor) do
    case required_tools(resolved) do
      [] -> :ok
      tools -> {:error, {:tools_unsupported, flavor, Enum.map(tools, & &1.name)}}
    end
  end

  defp required_tools(resolved) do
    resolved
    |> content_field(:tools)
    |> case do
      tools when is_list(tools) -> Enum.reject(tools, &Map.get(&1, :optional, false))
      _ -> []
    end
  end

  defp manifest_mcp_servers(tools) do
    tools
    |> Enum.map(fn tool ->
      {tool.name,
       %{
         "transport" => "ezagent-dispatch",
         "tool_name" => tool.name,
         "tool_type" => Atom.to_string(tool.type),
         "dispatch" => Map.get(tool, :action),
         "participant_ref" => Map.get(tool, :ref),
         "role_name" => Map.get(tool, :role_name),
         "ctx_caps" => []
       }
       |> compact_template_data()}
    end)
    |> Map.new()
  end

  defp compact_template_data(data) do
    data
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
