defmodule Ezagent.Socialware.DefinitionRegistry do
  @moduledoc """
  ConfigStore-backed resolver for socialware definitions.

  Definitions live under the structured non-URI ConfigStore subject
  `socialware:<name>` with ConfigObject key `"socialware"`, mirroring recipe
  storage's `recipe:<name>` subject. Workspace is a SEPARATE ConfigStore field,
  so it is not embedded in the subject (T1 project B).

  ## Seed model — DEFAULT NO-CLOBBER on divergence (Allen 2026-07-10)

  The built-in definitions (`builtin_definitions/0`) are the CODE/source
  definitions. The stored ConfigStore object is the RUNTIME definition. The boot
  seed (`seed_builtin_definitions/0`) reconciles them under a **default
  no-clobber** policy:

    * ABSENT (no stored object) → seed the code version (create-if-absent).
    * stored `content_hash` == code `content_hash` → silent no-op.
    * stored DIVERGES from code (`content_hash` differs) → **do NOT overwrite.**
      The runtime definition may carry an intentional operator change; silently
      applying the code version would clobber it. Instead SURFACE THE CONFLICT
      loud (a `Logger.warning` + a `[:ezagent, :socialware, :definition,
      :divergence]` telemetry event) and leave the stored object AS-IS.

  Applying the code version to a diverged stored definition is an EXPLICIT,
  content-safe operator action (`reseed_builtin_definition/1` +
  `mix ezagent.socialware.reseed_builtins --force`) — "change the data, not the
  code" is a decision the operator confirms, never one a reboot makes for them.

  This intentionally REPLACES the earlier §5.2 always-upgrade-on-hash-difference
  boot behavior for definitions: a seed-code change to an app definition no
  longer auto-migrates existing stored definitions on the next deploy; it
  surfaces the divergence and waits for an explicit `--force`. (The
  `ConfigStore.seed_object_upsert/1` always-upgrade primitive is retained — it is
  the force-apply path, invoked only on explicit operator request.)
  """

  require Logger

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ConfigObject, ConfigStore, ContentHash, Definition}

  @definition_key "socialware"
  @definition_layer "workspace"

  # Telemetry emitted when the boot seed finds a stored definition that diverges
  # from the code definition and (per the default no-clobber policy) declines to
  # overwrite it. Operators wire this to an alert / dashboard; the payload
  # carries the name, workspace, and both content hashes.
  @divergence_telemetry [:ezagent, :socialware, :definition, :divergence]

  # The built-in definition SEED-FAMILY `source_turn_id` prefix. The deterministic
  # first-seed turn is `<prefix>:<ws>:<name>`; a content-hash-carrying force-apply
  # turn is `<prefix>-upgrade:<ws>:<name>:<hash>`. Both feed the ConfigStore
  # `seed_object_upsert/1` primitive on the EXPLICIT force path
  # (`reseed_builtin_definition/1`); the boot lane never upgrades (it is
  # no-clobber). The turn ids stay stable so a re-forced apply is deterministically
  # idempotent.
  @definition_seed_prefix "socialware-definition-seed"

  # P0 §6/§11.2 (D-4) — the def-level RETRACT marker. A SEPARATE ConfigStore key
  # under the SAME `socialware:<name>` subject + `"workspace"` layer, keyed by
  # `(name, workspace)`. Keeping it OUT of the def `body` (its own key) means a
  # retract never enters the artifact's content-hash, so identity survives a
  # retract/restore cycle (§6.4). It rides the existing append-only object +
  # pointer machinery (no new table, no migration): set/clear is a `write_and_point`
  # of `%{"retracted" => bool}`; the current pointer is the current marker state.
  @retract_key "socialware_retract"

  @doc "The fixed ConfigObject key for socialware definition bodies."
  @spec definition_key() :: String.t()
  def definition_key, do: @definition_key

  @doc """
  Return the structured non-URI ConfigStore subject for a socialware `name`:
  `socialware:<name>` (T1 project B — an opaque subject, NOT a `<scheme>://`
  URI; workspace is a separate ConfigStore field). The `workspace_uri` argument
  is retained for call-site symmetry but is not part of the subject.
  """
  @spec definition_subject_uri(String.t() | URI.t(), String.t()) :: String.t()
  def definition_subject_uri(_workspace_uri, name)
      when is_binary(name) and name != "" do
    "socialware:#{name}"
  end

  @doc "Resolve a socialware definition through ConfigStore with system fallback."
  @spec lookup(String.t() | URI.t(), String.t()) ::
          {:ok, Definition.t(), ConfigObject.t()} | :error
  def lookup(workspace_uri, name) when is_binary(name) and name != "" do
    ws = uri_string(workspace_uri)

    with {:ok, %ConfigObject{} = object} <- resolve_object(ws, name),
         {:ok, %Definition{} = definition} <- Definition.new(object.body) do
      {:ok, definition, object}
    else
      _ -> :error
    end
  end

  @doc """
  Resolve a socialware definition by its EXACT revision id (`config_id`, the
  immutable `ConfigObject.id`) for a content-hash-addressed INSTALL (P1 §O-1),
  enforcing the SAME installable-scope gate as `list/1`/`lookup/2`.

  The catalog is cross-workspace but bare-name `lookup/2` resolves
  caller-workspace-first, so clicking a foreign PUBLIC card and installing could
  silently install a SAME-NAMED LOCAL def. Installing by `config_id` bypasses
  bare-name resolution and pins the EXACT revision the user saw (its env-stable
  `content_hash` is the identity shown/verified in the UI; `config_id` is the
  resolver key within THIS env's ConfigStore).

  SECURITY — this is a hard gate, not a convenience: `ConfigStore.fetch_object/1`
  alone returns ANY revision by id, including a PRIVATE foreign-workspace one, so
  without re-applying scope a caller could install any def by supplying its
  `config_id`. The revision MUST be **own-workspace, system, or public**
  (`visible_to_workspace?/4`, the same predicate `list/1` uses) AND its def MUST
  NOT be retracted (`retracted?/2`, consistent with the P0 retract fix — a
  retracted def is non-installable even by exact id).

  `expected_content_hash`, when supplied, must equal the resolved object's
  `content_hash` — a cheap cross-check that `config_id` still names the revision
  the UI displayed (defends against a stale pointer / UI drift).

  Returns `{:ok, Definition.t(), ConfigObject.t()}` or a loud `{:error, reason}`:
  `{:unknown_socialware_revision, id}`, `{:invalid_socialware_revision, id}`,
  `{:socialware_revision_not_installable, name}`, `{:socialware_revision_retracted, name}`,
  or `{:socialware_content_hash_mismatch, %{expected: _, got: _}}`.
  """
  @spec resolve_installable_revision(URI.t() | String.t(), String.t(), String.t() | nil) ::
          {:ok, Definition.t(), ConfigObject.t()} | {:error, term()}
  def resolve_installable_revision(workspace_uri, config_id, expected_content_hash \\ nil)
      when is_binary(config_id) and config_id != "" do
    ws = uri_string(workspace_uri)
    system_ws = system_workspace_uri()

    with {:ok, %ConfigObject{} = object} <- fetch_revision(config_id),
         {:ok, %Definition{} = definition} <- parse_revision(object),
         :ok <- authorize_installable_scope(definition, object, ws, system_ws),
         :ok <- refute_retracted(object, definition),
         :ok <- verify_content_hash(object, expected_content_hash) do
      {:ok, definition, object}
    end
  end

  defp fetch_revision(config_id) do
    case ConfigStore.fetch_object(config_id) do
      {:ok, %ConfigObject{} = object} -> {:ok, object}
      :none -> {:error, {:unknown_socialware_revision, config_id}}
    end
  end

  defp parse_revision(%ConfigObject{} = object) do
    case Definition.new(object.body) do
      {:ok, %Definition{} = definition} -> {:ok, definition}
      _ -> {:error, {:invalid_socialware_revision, object.id}}
    end
  end

  defp authorize_installable_scope(
         %Definition{} = definition,
         %ConfigObject{workspace_uri: object_ws},
         ws,
         system_ws
       ) do
    if visible_to_workspace?(definition, object_ws, ws, system_ws) do
      :ok
    else
      {:error, {:socialware_revision_not_installable, definition.name}}
    end
  end

  defp refute_retracted(%ConfigObject{workspace_uri: object_ws}, %Definition{name: name}) do
    if retracted?(object_ws, name) do
      {:error, {:socialware_revision_retracted, name}}
    else
      :ok
    end
  end

  defp verify_content_hash(_object, nil), do: :ok

  defp verify_content_hash(%ConfigObject{content_hash: hash}, expected)
       when is_binary(expected) do
    if hash == expected do
      :ok
    else
      {:error, {:socialware_content_hash_mismatch, %{expected: expected, got: hash}}}
    end
  end

  @doc """
  True when `(name, workspace)` carries a RETRACT marker (P0 §6). Consulted by
  `list/1` (`list_entry_for/3`) and the `lookup/2` PUBLIC fallback
  (`public_object/1`), always keyed by the OBJECT's OWN `workspace_uri` so a
  retract in one workspace never hides a foreign-workspace object of the same name.
  """
  @spec retracted?(URI.t() | String.t(), String.t()) :: boolean()
  def retracted?(workspace_uri, name) when is_binary(name) and name != "" do
    ws = uri_string(workspace_uri)

    case ConfigStore.resolve(
           @definition_layer,
           ws,
           definition_subject_uri(ws, name),
           @retract_key
         ) do
      {:ok, %ConfigObject{body: body}} -> Map.get(body, "retracted") == true
      :none -> false
    end
  end

  @doc """
  Set (or clear) the def-level retract marker for `(name, workspace)` (P0 §6.2/§6.4).

  Writes a NEW immutable marker object via the append-only `ConfigStore` and
  advances the `"socialware_retract"` pointer to it. The def's own revisions are
  never touched, so restore (`retracted? == false`) resumes the def at its
  last-published revision with its original `content_hash`. Admin-gating lives at
  the `ConfigGovernance.Socialware.retract/2` boundary that calls this.
  """
  @spec set_retracted(URI.t() | String.t(), String.t(), boolean(), URI.t() | String.t()) ::
          {:ok, ConfigObject.t()} | {:error, term()}
  def set_retracted(workspace_uri, name, retracted?, actor_uri)
      when is_binary(name) and name != "" and is_boolean(retracted?) do
    ws = uri_string(workspace_uri)

    ConfigStore.write_and_point(%{
      layer: @definition_layer,
      workspace_uri: ws,
      subject_uri: definition_subject_uri(ws, name),
      key: @retract_key,
      body: %{"retracted" => retracted?},
      actor_uri: uri_string(actor_uri),
      source_turn_id:
        "socialware-retract:#{ws}:#{name}:#{System.unique_integer([:positive, :monotonic])}"
    })
    |> case do
      {:ok, %{object: object}} -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Boot seed for the built-in definitions — DEFAULT NO-CLOBBER (Allen 2026-07-10).

  For each built-in: seed it if ABSENT, no-op if the stored object already
  matches the code (`content_hash`), and — if the stored object DIVERGES from the
  code — SURFACE the conflict (`Logger.warning` + a `:divergence` telemetry
  event) and leave the stored object untouched. It NEVER overwrites a diverged
  stored definition; that is the explicit `reseed_builtin_definition/1` force
  path.

  Returns `:ok` (a divergence is a surfaced-but-non-fatal condition, not a boot
  error) or `{:error, reason}` on a genuine write failure of an ABSENT seed.
  """
  @spec seed_builtin_definitions() :: :ok | {:error, term()}
  def seed_builtin_definitions do
    Enum.reduce_while(builtin_definitions(), :ok, fn definition, :ok ->
      case seed_builtin_definition_no_clobber(definition, system_workspace_uri()) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Read-only divergence report for the built-in definitions (no side effects).

  Returns one entry per built-in whose STORED system-workspace object diverges
  from the CODE definition:
  `%{name, workspace_uri, stored_hash, code_hash}`. Built-ins that are absent or
  current are omitted. Used by `mix ezagent.socialware.reseed_builtins` (no
  `--force`) to show the operator exactly what a `--force` would change.
  """
  @spec builtin_definition_divergences() :: [map()]
  def builtin_definition_divergences do
    workspace_uri = system_workspace_uri()

    Enum.flat_map(builtin_definitions(), fn definition ->
      case builtin_definition_state(definition, workspace_uri) do
        {:diverged, stored_hash, code_hash} ->
          [
            %{
              name: definition.name,
              workspace_uri: workspace_uri,
              stored_hash: stored_hash,
              code_hash: code_hash
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  OPERATOR FORCE-RESEED — apply the CODE version of ONE built-in socialware
  definition BY NAME to the stored system-workspace definition NOW, overriding a
  divergence.

  This is the EXPLICIT "change the data, not the code" path (Allen 2026-07-10):
  the boot seed (`seed_builtin_definitions/0`) deliberately does NOT overwrite a
  diverged stored definition, so applying the code version is only ever an
  operator-confirmed action — this function, or the
  `mix ezagent.socialware.reseed_builtins <name> --force` task that wraps it.

  It is content-safe: it runs `ConfigStore.seed_object_upsert/1` (nil prefix =
  always-apply on a hash difference), which APPENDS a new immutable object and
  REPOINTS the pointer — never a raw in-place `UPDATE`. An already-current
  definition is a no-op (`:exists`); an absent one is seeded.

  ## Non-clobber scope

  Only the SYSTEM-workspace built-in pointer is touched. A tenant workspace that
  published its OWN revision of this definition holds a SEPARATE pointer row
  (`write_definition/2` writes under the caller's workspace), which this call
  never resolves, so tenant overrides are never affected.

  Returns the `seed_object_upsert/1` result
  (`{:ok, :seeded | :exists | :already_upgraded}`), or
  `{:error, {:unknown_builtin_definition, name}}` if no built-in of that name
  exists.
  """
  @spec reseed_builtin_definition(String.t()) ::
          {:ok, :seeded | :exists | :already_upgraded} | {:error, term()}
  def reseed_builtin_definition(name) when is_binary(name) and name != "" do
    case Enum.find(builtin_definitions(), &(&1.name == name)) do
      %Definition{} = definition ->
        force_apply_builtin_definition(definition, system_workspace_uri())

      nil ->
        {:error, {:unknown_builtin_definition, name}}
    end
  end

  # Boot / non-force lane: seed-if-absent, no-op if current, surface + skip on
  # divergence. Never overwrites a diverged stored definition.
  defp seed_builtin_definition_no_clobber(%Definition{} = definition, workspace_uri) do
    workspace_uri = uri_string(workspace_uri)

    case builtin_definition_state(definition, workspace_uri) do
      :absent ->
        seed_builtin_definition_if_absent(definition, workspace_uri)

      :current ->
        {:ok, :exists}

      {:diverged, stored_hash, code_hash} ->
        surface_definition_divergence(definition.name, workspace_uri, stored_hash, code_hash)
        {:ok, :diverged}
    end
  end

  # Classify a built-in against its stored system-workspace object (pure read):
  # `:absent` (no pointer), `:current` (hashes match), or
  # `{:diverged, stored_hash, code_hash}`. A legacy object with a NULL
  # `content_hash` column is hashed from its stored body so it is not reported as
  # a spurious divergence.
  defp builtin_definition_state(%Definition{} = definition, workspace_uri) do
    subject = definition_subject_uri(workspace_uri, definition.name)
    code_hash = definition |> Definition.body() |> ContentHash.of()

    case ConfigStore.resolve(@definition_layer, workspace_uri, subject, @definition_key) do
      :none ->
        :absent

      {:ok, %ConfigObject{} = object} ->
        stored_hash = object.content_hash || ContentHash.of(object.body)

        if stored_hash == code_hash do
          :current
        else
          {:diverged, stored_hash, code_hash}
        end
    end
  end

  # Create-if-absent seed of a built-in (race-safe via ConfigStore). This is only
  # reached when no pointer exists, so it never overwrites anything.
  defp seed_builtin_definition_if_absent(%Definition{} = definition, workspace_uri) do
    subject = definition_subject_uri(workspace_uri, definition.name)

    ConfigStore.seed_object_if_no_pointer(%{
      layer: @definition_layer,
      workspace_uri: workspace_uri,
      subject_uri: subject,
      key: @definition_key,
      body: Definition.body(definition),
      actor_uri: default_seed_actor(),
      source_turn_id: "#{@definition_seed_prefix}:#{workspace_uri}:#{definition.name}",
      collision_tag: {:socialware_definition_seed_collision, definition.name}
    })
  end

  # Loud, operator-visible surfacing of a code-vs-stored divergence the boot seed
  # declined to overwrite (Allen 2026-07-10). Log + telemetry; no side effect on
  # the stored definition.
  defp surface_definition_divergence(name, workspace_uri, stored_hash, code_hash) do
    Logger.warning(
      "socialware definition #{inspect(name)} in #{workspace_uri} DIVERGES from code " <>
        "(stored #{inspect(stored_hash)} vs code #{inspect(code_hash)}) — NOT overwriting " <>
        "(default no-clobber policy). To apply the code version run " <>
        "`mix ezagent.socialware.reseed_builtins #{name} --force`, or change the code to " <>
        "match the stored definition."
    )

    :telemetry.execute(
      @divergence_telemetry,
      %{count: 1},
      %{
        name: name,
        workspace_uri: workspace_uri,
        stored_hash: stored_hash,
        code_hash: code_hash
      }
    )

    :ok
  end

  @doc "Seed one socialware definition into ConfigStore without clobbering overrides."
  @spec seed_definition_if_absent(Definition.t() | map(), keyword()) ::
          {:ok, :seeded | :exists} | {:error, term()}
  def seed_definition_if_absent(definition_or_attrs, opts \\ []) do
    with {:ok, %Definition{} = definition} <- normalize_definition(definition_or_attrs) do
      workspace_uri = opts |> Keyword.get(:workspace_uri, system_workspace_uri()) |> uri_string()
      subject = definition_subject_uri(workspace_uri, definition.name)
      actor = Keyword.get(opts, :actor_uri, default_seed_actor())

      ConfigStore.seed_object_if_no_pointer(%{
        layer: @definition_layer,
        workspace_uri: workspace_uri,
        subject_uri: subject,
        key: @definition_key,
        body: Definition.body(definition),
        actor_uri: actor,
        source_turn_id: "#{@definition_seed_prefix}:#{workspace_uri}:#{definition.name}",
        collision_tag: {:socialware_definition_seed_collision, definition.name}
      })
    end
  end

  @doc "Write a new current ConfigObject version for a workspace socialware definition."
  @spec write_definition(Definition.t() | map(), keyword()) ::
          {:ok, ConfigObject.t()} | {:error, term()}
  def write_definition(definition_or_attrs, opts \\ []) do
    with {:ok, %Definition{} = definition} <- normalize_definition(definition_or_attrs),
         {:ok, workspace_uri} <- required_uri_opt(opts, :workspace_uri),
         {:ok, actor} <- required_uri_opt(opts, :actor_uri),
         :ok <- authorize_definition_write(opts, workspace_uri),
         :ok <- authorize_public_scope_write(opts, definition),
         subject = definition_subject_uri(workspace_uri, definition.name),
         source_turn_id =
           Keyword.get_lazy(opts, :source_turn_id, fn ->
             unique_source_turn_id(workspace_uri, definition.name)
           end),
         {:ok, %{object: %ConfigObject{} = object}} <-
           ConfigStore.write_and_point(%{
             layer: @definition_layer,
             workspace_uri: workspace_uri,
             subject_uri: subject,
             key: @definition_key,
             body: Definition.body(definition),
             actor_uri: actor,
             source_turn_id: source_turn_id
           }) do
      {:ok, object}
    end
  end

  @doc "List installable socialware definitions visible to a caller workspace."
  @spec list(URI.t() | String.t()) :: [map()]
  def list(workspace_uri) do
    ws = uri_string(workspace_uri)
    system_ws = system_workspace_uri()

    @definition_layer
    |> ConfigStore.list_current_objects(@definition_key)
    |> Enum.flat_map(&list_entry_for(&1, ws, system_ws))
    |> Enum.sort_by(fn entry -> {visibility_rank(entry, ws, system_ws), entry.name} end)
    |> Enum.reduce(%{}, fn entry, acc -> Map.put_new(acc, entry.name, entry) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc "Return the in-repo built-in definitions used as boot seed data."
  @spec builtin_definitions() :: [Definition.t()]
  def builtin_definitions do
    [
      %Definition{
        name: "chat",
        bases: Session.chat_behaviors(),
        shape: [],
        visibility_policy: %{publish_policy: :auto, web_anon_access: false}
      },
      %Definition{
        name: "orchestrator",
        title: "Orchestrator",
        description: "Stock cc orchestrator team front desk.",
        # `uses: ["cc"]` names the PLUGIN dependency (conformance checks
        # `uses_plugins_installed`); it stays "cc" because `cc-custom` is a
        # provider-configurable FLAVOR hosted by the `ezagent_plugin_cc`
        # plugin, not a separate plugin.
        uses: ["cc"],
        roles: [
          %{
            role_name: "orchestrator",
            fill: :agent,
            recipe: "orchestrator",
            # cc-custom + the "deepseek" backend profile (flavors merged #1324;
            # orchestrator switched in #1332; flavor generalized to cc-custom in
            # cc-custom-backends PR-5): the orchestrator authenticates via
            # DEEPSEEK_API_KEY, needs no host
            # `~/.claude` OAuth login (no #161 co-tenant issue), and boots
            # authenticated. #1332 switched the cc-orchestrator AgentTemplate seed
            # (`CcOrchestratorSeed`) to `cc-deepseek` but NOT this app-definition
            # role flavor, so `App=Orchestrator` still installed a `cc` orchestrator
            # from the stored socialware definition; that change (and this PR-5
            # generalization, which adds the additive role-slot `provider` key —
            # spec 2026-07-17 Q2) brings the two seed representations into
            # agreement. NOTE (default no-clobber policy, UNCHANGED): a
            # stored orchestrator definition that already diverges from this code
            # (e.g. the pre-#1332 `cc` one) is NOT auto-migrated on boot — the boot
            # seed surfaces the divergence and leaves it as-is; applying this code
            # version is an explicit `reseed_builtin_definition/1` /
            # `mix ezagent.socialware.reseed_builtins orchestrator --force`.
            flavor: "cc-custom",
            provider: "deepseek"
          }
        ],
        views: [],
        routing_rules: [],
        visibility_policy: %{publish_policy: :auto, web_anon_access: false}
      },
      %Definition{
        name: "socialware",
        bases: [
          Ezagent.ActionSet.Session,
          Ezagent.ActionSet.Publisher.SessionImpl
        ],
        shape: [
          Ezagent.ActionSet.Turn,
          Ezagent.ActionSet.Surface,
          Ezagent.ActionSet.SupervisorApproval
        ],
        adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      }
    ]
  end

  @doc "Canonical system workspace URI string for built-in socialware definitions."
  @spec system_workspace_uri() :: String.t()
  def system_workspace_uri, do: :system |> Ezagent.URI.workspace() |> URI.to_string()

  defp resolve_object(ws, name) do
    system_ws = system_workspace_uri()

    case ConfigStore.resolve(
           @definition_layer,
           ws,
           definition_subject_uri(ws, name),
           @definition_key
         ) do
      # P0 §6 — a RETRACTED same-workspace object is filtered here too, not just in
      # the PUBLIC fallback: `lookup/2` is the NEW-install/new-selection route
      # (`Installation.resolve_install/2` fallback), so an owning workspace must not
      # be able to freshly install its own retracted def by ref. A retracted object
      # falls through to the system/public fallback (which also filters retracted),
      # keeping `lookup` uniformly retract-aware. EXISTING pinned installs are
      # unaffected — they resolve via `ConfigStore.fetch_object(config_id)`, never
      # through `lookup` (grandfathering, T-Ret-b).
      {:ok, object} ->
        if retracted?(ws, name) do
          resolve_object_fallback(ws, name, system_ws)
        else
          {:ok, object}
        end

      :none ->
        resolve_object_fallback(ws, name, system_ws)
    end
  end

  # The system → public fallback chain used when a `(name, caller_ws)` object is
  # absent OR filtered out as retracted. The system branch is only consulted for a
  # non-system caller; the PUBLIC fallback already filters retracted objects.
  defp resolve_object_fallback(ws, name, system_ws) when ws != system_ws do
    ConfigStore.resolve(
      @definition_layer,
      system_ws,
      definition_subject_uri(system_ws, name),
      @definition_key
    )
    |> case do
      {:ok, object} -> {:ok, object}
      :none -> public_object(name)
    end
  end

  defp resolve_object_fallback(_ws, name, _system_ws), do: public_object(name)

  defp public_object(name) do
    @definition_layer
    |> ConfigStore.list_current_objects(@definition_key)
    |> Enum.find(fn %ConfigObject{subject_uri: subject} = object ->
      subject == definition_subject_uri(object.workspace_uri, name) and public_object?(object) and
        not retracted?(object.workspace_uri, name)
    end)
    |> case do
      %ConfigObject{} = object -> {:ok, object}
      nil -> :error
    end
  end

  defp public_object?(%ConfigObject{} = object) do
    case Definition.new(object.body) do
      {:ok, %Definition{} = definition} -> public?(definition)
      _ -> false
    end
  end

  defp normalize_definition(%Definition{} = definition), do: {:ok, definition}
  defp normalize_definition(attrs) when is_map(attrs), do: Definition.new(attrs)

  defp list_entry_for(%ConfigObject{} = object, caller_ws, system_ws) do
    with {:ok, %Definition{} = definition} <- Definition.new(object.body),
         true <- visible_to_workspace?(definition, object.workspace_uri, caller_ws, system_ws),
         false <- retracted?(object.workspace_uri, definition.name) do
      [
        %{
          name: definition.name,
          version: definition.version,
          title: definition.title || definition.name,
          description: definition.description || "",
          roles: definition.roles,
          public?: public?(definition),
          workspace_uri: object.workspace_uri,
          config_id: object.id,
          content_hash: object.content_hash
        }
      ]
    else
      _ -> []
    end
  end

  defp visible_to_workspace?(definition, object_ws, caller_ws, system_ws) do
    object_ws == caller_ws or object_ws == system_ws or public?(definition)
  end

  defp public?(%Definition{visibility_policy: %{scope: :public}}), do: true
  defp public?(_), do: false

  defp visibility_rank(%{workspace_uri: ws}, ws, _system_ws), do: 0
  defp visibility_rank(%{workspace_uri: system_ws}, _ws, system_ws), do: 1
  defp visibility_rank(_entry, _ws, _system_ws), do: 2

  defp required_uri_opt(opts, :workspace_uri) do
    case Keyword.fetch(opts, :workspace_uri) do
      {:ok, uri} -> {:ok, uri_string(uri)}
      :error -> {:error, :missing_socialware_definition_workspace}
    end
  end

  defp required_uri_opt(opts, :actor_uri) do
    case Keyword.fetch(opts, :actor_uri) do
      {:ok, uri} -> {:ok, uri_string(uri)}
      :error -> {:error, :missing_socialware_definition_actor}
    end
  end

  defp authorize_definition_write(opts, workspace_uri) do
    case Keyword.get(opts, :authority) do
      :system_seed ->
        if workspace_uri == system_workspace_uri() do
          :ok
        else
          {:error, {:invalid_socialware_definition_system_seed_workspace, workspace_uri}}
        end

      _ ->
        case Keyword.fetch(opts, :caller_workspace_uri) do
          {:ok, caller_workspace_uri} ->
            caller_workspace_uri = uri_string(caller_workspace_uri)

            if caller_workspace_uri == workspace_uri do
              :ok
            else
              {:error,
               {:cross_workspace_socialware_definition_write_denied,
                %{caller_workspace_uri: caller_workspace_uri, workspace_uri: workspace_uri}}}
            end

          :error ->
            {:error, :missing_socialware_definition_caller_workspace}
        end
    end
  end

  # SECURITY (#165): publishing/authoring a socialware definition whose
  # visibility scope is `:public` promotes it into the CROSS-TENANT installable
  # catalog (`list/1` + the `lookup/2`/`resolve_installable_revision/3` public
  # fallback), so it MUST require ADMIN authority — matching the
  # `ConfigGovernance.Socialware.authorize_public_scope` CR path. PRIVATE writes
  # keep their prior authority (owning-workspace caller, gated by
  # `authorize_definition_write/2`); this gate never fires for them. The
  # `:system_seed` authority is the trusted boot-seed path for built-ins and is
  # exempt (its workspace is already pinned to `system`). The admin check uses
  # the RAW `%URI{}` caller (`:actor_uri` opt) so `home_is_system?` matches, plus
  # the caller's real `:caps` threaded from the authoring surface.
  defp authorize_public_scope_write(opts, %Definition{} = definition) do
    cond do
      not public?(definition) ->
        :ok

      Keyword.get(opts, :authority) == :system_seed ->
        :ok

      Ezagent.Identity.AdminAuthority.admin?(
        caller_uri(Keyword.get(opts, :actor_uri)),
        Keyword.get(opts, :caps, [])
      ) ->
        :ok

      true ->
        {:error, :public_socialware_requires_admin}
    end
  end

  defp caller_uri(%URI{} = uri), do: uri

  defp caller_uri(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = parsed} -> parsed
      _ -> nil
    end
  end

  defp caller_uri(_), do: nil

  # EXPLICIT force-apply primitive (`reseed_builtin_definition/1`): apply the code
  # definition to the stored one via the ConfigStore three-state seed primitive
  # (`seed_object_upsert/1`). NO `:seed_family_prefix` is passed → always-apply on
  # a content-hash difference (APPEND a new immutable object + REPOINT, never a
  # raw UPDATE). The primitive owns resolve → hash-compare → apply →
  # unique-`source_turn_id` retry tolerance (`{:ok, :already_upgraded}`, the #1235
  # crash-restart guard). This is invoked ONLY on an explicit operator request —
  # the boot lane (`seed_builtin_definition_no_clobber/2`) never calls it.
  defp force_apply_builtin_definition(%Definition{} = definition, workspace_uri) do
    workspace_uri = uri_string(workspace_uri)
    subject = definition_subject_uri(workspace_uri, definition.name)
    body = Definition.body(definition)
    new_hash = Definition.content_hash(body)

    ConfigStore.seed_object_upsert(%{
      layer: @definition_layer,
      workspace_uri: workspace_uri,
      subject_uri: subject,
      key: @definition_key,
      body: body,
      actor_uri: default_seed_actor(),
      source_turn_id: "#{@definition_seed_prefix}:#{workspace_uri}:#{definition.name}",
      upgrade_source_turn_id:
        builtin_upgrade_source_turn_id(workspace_uri, definition.name, new_hash),
      collision_tag: {:socialware_definition_seed_collision, definition.name}
    })
  end

  defp default_seed_actor, do: Ezagent.URI.user(:system, :admin) |> URI.to_string()

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri

  defp builtin_upgrade_source_turn_id(workspace_uri, name, hash) do
    "#{@definition_seed_prefix}-upgrade:#{workspace_uri}:#{name}:#{hash}"
  end

  defp unique_source_turn_id(workspace_uri, name) do
    "socialware-definition-write:#{workspace_uri}:#{name}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
