defmodule Ezagent.Socialware.Installation do
  @moduledoc """
  Session ↔ socialware install relation.

  A SessionTemplate's `installs` field names ConfigStore-backed socialware
  definitions. Materialization writes a per-session ConfigObject record and
  threads the definitions' behavior union into the Session's `:kind_base`.
  """

  alias Ezagent.Socialware.{ConfigObject, ConfigStore, Definition, DefinitionRegistry}

  @default_installs ["chat"]
  @install_layer "session"
  @install_key_prefix "install:"

  @type install_spec :: %{
          ref: String.t(),
          config: map(),
          config_id: String.t() | nil,
          content_hash: String.t() | nil
        }

  @doc "Default socialware refs for legacy SessionTemplates with no installs field."
  @spec default_installs() :: [String.t()]
  def default_installs, do: @default_installs

  @doc "Read the raw installs list from SessionTemplate content, defaulting to chat."
  @spec installs_from_template(map()) :: [term()]
  def installs_from_template(content) when is_map(content) do
    case Map.get(content, :installs) || Map.get(content, "installs") do
      installs when is_list(installs) -> installs
      _ -> @default_installs
    end
  end

  def installs_from_template(_), do: @default_installs

  @doc "Parse a SessionTemplate's install declarations into canonical install specs."
  @spec parsed_installs_from_template(map()) :: {:ok, [install_spec()]} | {:error, term()}
  def parsed_installs_from_template(content) when is_map(content),
    do: parse_installs(installs_from_template(content))

  def parsed_installs_from_template(_content), do: parse_installs(@default_installs)

  @doc "Resolve a SessionTemplate's install declarations to definitions and ConfigObjects."
  @spec resolved_template_installs(map(), URI.t() | String.t()) ::
          {:ok, [{Definition.t(), ConfigObject.t(), install_spec()}]} | {:error, term()}
  def resolved_template_installs(content, workspace_uri) when is_map(content) do
    resolved_template_installs(content, workspace_uri, lookup_fun: &DefinitionRegistry.lookup/2)
  end

  @doc "Resolve installs using a caller-supplied definition lookup function."
  @spec resolved_template_installs(map(), URI.t() | String.t(), keyword()) ::
          {:ok, [{Definition.t(), ConfigObject.t() | nil, install_spec()}]} | {:error, term()}
  def resolved_template_installs(content, workspace_uri, opts) when is_map(content) do
    with {:ok, installs} <- parsed_installs_from_template(content),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri, opts) do
      {:ok, definitions}
    end
  end

  @doc "Resolve a SessionTemplate's installs into the Session host behavior set."
  @spec behavior_set_for_template(map(), URI.t() | String.t()) ::
          {:ok, [module()]} | {:error, term()}
  def behavior_set_for_template(content, workspace_uri) when is_map(content) do
    behavior_set_for_template(content, workspace_uri, lookup_fun: &DefinitionRegistry.lookup/2)
  end

  def behavior_set_for_template(_content, workspace_uri),
    do: behavior_set_for_template(%{}, workspace_uri)

  @doc "Resolve a SessionTemplate's behavior set using a caller-supplied definition lookup."
  @spec behavior_set_for_template(map(), URI.t() | String.t(), keyword()) ::
          {:ok, [module()]} | {:error, term()}
  def behavior_set_for_template(content, workspace_uri, opts) when is_map(content) do
    with {:ok, installs} <- parse_installs(installs_from_template(content)),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri, opts) do
      definitions
      |> Enum.flat_map(fn {definition, _object, _install} -> Definition.behaviors(definition) end)
      |> Enum.uniq()
      |> case do
        [] -> {:error, :empty_install_behavior_set}
        behaviors -> {:ok, behaviors}
      end
    end
  end

  def behavior_set_for_template(_content, workspace_uri, opts),
    do: behavior_set_for_template(%{}, workspace_uri, opts)

  @doc """
  Freeze-pin (SPEC §4.1/§4.4, Decision A) — the single shared freeze step.

  Resolve every declared install in `content` to its CURRENT published
  revision-id and BAKE that pinned `config_id` (+ env-independent `content_hash`)
  into the content's `installs` entries. The returned content, fed to
  `behavior_set_for_template/2` (or `install_template_installs/4`), then resolves
  the FROZEN revision — a later publish of the def does NOT change the behaviors
  of a session created from this content.

  Idempotent: an entry that already carries a `config_id` keeps it (freezing
  twice is a no-op). An entry whose ref cannot be resolved fails loud with the
  same `{:unknown_socialware_install, ref}` `behavior_set_for_template/2` would
  raise, so a mis-declared install never silently degrades to a live lookup.

  §4.4: this helper MUST be applied at EVERY production `behavior_set_for_template/2`
  call site (`SessionCreator`, `EzagentPluginHello.App.ensure_app/3`) before the
  behavior set is resolved.
  """
  @spec freeze_template_installs(map(), URI.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def freeze_template_installs(content, workspace_uri) when is_map(content) do
    with {:ok, installs} <- parse_installs(installs_from_template(content)),
         {:ok, frozen} <- freeze_installs(installs, workspace_uri) do
      {:ok, put_installs(content, frozen)}
    end
  end

  def freeze_template_installs(content, _workspace_uri), do: {:ok, content}

  @doc """
  Derive the session `owner_uri` a template's installs reproduce. Definitions do
  not carry owner instance URIs; the primary install resolves owner via
  `Definition.owner_uri/2`, which is installer/caller-derived. A template with no
  resolvable installs yields `{:ok, caller}`.
  """
  @spec owner_uri_for_template(map(), URI.t() | String.t(), URI.t() | nil) ::
          {:ok, URI.t() | nil} | {:error, term()}
  def owner_uri_for_template(content, workspace_uri, caller) when is_map(content) do
    with {:ok, definitions} <- resolved_template_installs(content, workspace_uri) do
      case definitions do
        [{%Definition{} = definition, _object, _install} | _] ->
          {:ok, Definition.owner_uri(definition, caller)}

        [] ->
          {:ok, caller}
      end
    end
  end

  @doc """
  Freeze-pin (repair path, §4.4) — re-pin a template's installs to the frozen
  revisions recorded in a SESSION's own per-session install records.

  Fresh create bakes the pin into the session's install records (via
  `install_template_installs/4`) but NOT back into the shared SessionTemplate
  content. The repair/rematerialization path re-reads that (unpinned) template
  content, so without this it would resolve each install LIVE — a later
  publish/retract would change an EXISTING session's behaviors on repair,
  breaking the freeze-pin invariant. This overlays each declared install's frozen
  `config_id` (+ `content_hash`) from the session's install record onto the
  content, so the pin-honoring `resolved_template_installs/2` rebuilds from the
  SAME revision the session was created with.

  An install already carrying a `config_id` keeps it (idempotent). An install
  with NO session record (e.g. a ref newly added to the template after create)
  keeps its bare ref and resolves live — a never-installed ref is not
  grandfathered by a pin that never existed.
  """
  @spec pin_installs_from_session(URI.t(), map()) :: map()
  def pin_installs_from_session(%URI{scheme: "session"} = session_uri, content)
      when is_map(content) do
    case parsed_installs_from_template(content) do
      {:ok, installs} ->
        pinned = Enum.map(installs, &pin_install_from_session_record(session_uri, &1))
        put_installs(content, pinned)

      {:error, _} ->
        content
    end
  end

  def pin_installs_from_session(_session_uri, content), do: content

  @doc """
  Retract every per-session install pointer for `session_uri`.

  Rollback keeps ConfigStore append-only: each current `install:<ref>` pointer is
  advanced to a tombstone object instead of deleting rows. A later fresh create
  can then seed the same ref again to the current published definition.
  """
  @spec retract_session_installs(URI.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def retract_session_installs(%URI{scheme: "session"} = session_uri, actor_uri) do
    workspace = Ezagent.URI.workspace_of(session_uri)

    session_uri
    |> ConfigStore.list_keys_for_subject()
    |> Enum.filter(&String.starts_with?(&1, @install_key_prefix))
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case retract_session_install(session_uri, workspace, key, actor_uri) do
        {:ok, _object} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def retract_session_installs(_session_uri, _actor_uri), do: :ok

  defp pin_install_from_session_record(%URI{} = session_uri, install) do
    workspace = Ezagent.URI.workspace_of(session_uri)
    key = install_key(install.ref)

    case ConfigStore.resolve(@install_layer, workspace, session_uri, key) do
      {:ok, %ConfigObject{body: body}} ->
        %{
          install
          | config_id: install.config_id || Map.get(body, "definition_config_id"),
            content_hash: install.content_hash || Map.get(body, "definition_content_hash")
        }

      :none ->
        install
    end
  end

  @doc "Materialize per-session install records for a SessionTemplate's installs."
  @spec install_template_installs(URI.t(), URI.t() | String.t(), map(), URI.t() | String.t()) ::
          :ok | {:error, term()}
  def install_template_installs(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        content,
        actor_uri
      ) do
    with {:ok, installs} <- parse_installs(installs_from_template(content)),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri) do
      Enum.reduce_while(definitions, :ok, fn {definition, object, install}, :ok ->
        case seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "Repoint all per-session install records to the definitions named by a template."
  @spec repoint_template_installs(URI.t(), URI.t() | String.t(), map(), URI.t() | String.t()) ::
          :ok | {:error, term()}
  def repoint_template_installs(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        content,
        actor_uri
      ) do
    # SPEC §4.2 item 4 — repoint is the SOLE explicit upgrade path: it drops any
    # frozen pin and re-resolves each ref to the CURRENT published revision, so an
    # install advances forward (a pin-honoring resolve here would no-op).
    with {:ok, definitions} <-
           resolved_template_installs(strip_install_pins(content), workspace_uri) do
      Enum.reduce_while(definitions, :ok, fn {definition, object, install}, :ok ->
        case point_session_install(
               session_uri,
               workspace_uri,
               install,
               definition,
               object,
               actor_uri
             ) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "True when any installed socialware definition allows anonymous web access."
  @spec web_anon_access?(URI.t()) :: boolean()
  def web_anon_access?(%URI{scheme: "session"} = session_uri) do
    session_uri
    |> installed_definitions()
    |> Enum.any?(fn %Definition{visibility_policy: policy} ->
      Map.get(policy, :web_anon_access, false) == true
    end)
  end

  def web_anon_access?(_), do: false

  @doc """
  T2-2b — the view read-caps an anonymous visitor is minted with for
  `session_uri`: for every PUBLIC installed definition
  (`visibility_policy.web_anon_access == true`), one `<sw>_render` cap per action
  of each of the definition's declared `views` ActionSets.

  This is the fine-grained half of the two-layer gate: openness
  (`web_anon_access`) decides whether an anon is minted at all; these caps decide
  which VIEWS that anon can see. A view of a NON-public installed definition
  (e.g. kanban-private in a hello-public session) contributes NO cap, so the anon
  cannot render it (`SessionView.authorize_view/3` denies).

  The cap shape is exactly what `SessionView.render_needed_caps/2` checks
  (`cap(:session, view_actionset, action, <session>, <ws>)`), so the mint and the
  gate agree by construction. `granted_by` = the session owner (the configurer of
  the public_view rule), falling back to the admin entity — Decision #154's named
  granter, never a `system://` principal. JSON-serializable (concrete instance) so
  it lands in the anon's `caps_json`.
  """
  @spec anon_view_caps(URI.t()) :: [Ezagent.Capability.t()]
  def anon_view_caps(%URI{scheme: "session"} = session_uri) do
    granter = anon_view_granter(session_uri)
    instance = Ezagent.URI.instance(session_uri)
    workspace = Ezagent.Capability.workspace_of(session_uri)

    session_uri
    |> installed_definitions()
    |> Enum.filter(fn %Definition{visibility_policy: policy} ->
      Map.get(policy, :web_anon_access, false) == true
    end)
    |> Enum.flat_map(fn %Definition{views: views} -> views end)
    |> Enum.uniq()
    |> Enum.flat_map(&view_render_caps(&1, instance, workspace, granter))
  end

  def anon_view_caps(_), do: []

  defp view_render_caps(view_module, instance, workspace, granter) when is_atom(view_module) do
    for action <- view_actions(view_module) do
      %Ezagent.Capability{
        Ezagent.Capability.cap(:session, view_module, action, instance, workspace)
        | granted_by: granter,
          granted_at: DateTime.utc_now()
      }
    end
  end

  defp view_actions(view_module) do
    if Code.ensure_loaded?(view_module) and function_exported?(view_module, :actions, 0) do
      view_module.actions()
    else
      []
    end
  rescue
    _ -> []
  end

  defp anon_view_granter(%URI{} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> Ezagent.Entity.User.admin_uri()
    end
  end

  @doc "Return the effective publish policy for a session's installed socialwares."
  @spec publish_policy(URI.t()) :: :auto | :supervised
  def publish_policy(%URI{scheme: "session"} = session_uri) do
    if Enum.any?(installed_definitions(session_uri), &supervised?/1) do
      :supervised
    else
      :auto
    end
  end

  def publish_policy(_), do: :auto

  @doc "Return true when `session_uri` has a current install record for `ref`."
  @spec installed?(URI.t(), String.t()) :: boolean()
  def installed?(%URI{scheme: "session"} = session_uri, ref) when is_binary(ref) do
    install_state(session_uri, ref) == :installed
  end

  def installed?(_session_uri, _ref), do: false

  @doc "Repoint one session install record to a newer socialware definition object."
  @spec point_session_install(
          URI.t(),
          URI.t() | String.t(),
          install_spec(),
          Definition.t(),
          ConfigObject.t(),
          URI.t() | String.t()
        ) :: {:ok, ConfigObject.t()} | {:error, term()}
  def point_session_install(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        install,
        %Definition{} = definition,
        %ConfigObject{} = object,
        actor_uri
      )
      when is_map(install) do
    ref = install.ref

    with {:ok, %{object: %ConfigObject{} = install_object}} <-
           ConfigStore.write_and_point(%{
             layer: @install_layer,
             workspace_uri: workspace_uri,
             subject_uri: session_uri,
             key: install_key(ref),
             body: install_body(ref, install.config, definition, object),
             actor_uri: actor_uri,
             source_turn_id: unique_source_turn_id("socialware-install", session_uri, ref)
           }) do
      {:ok, install_object}
    end
  end

  @doc "Return the exact socialware definitions currently installed on a session."
  @spec installed_definitions(URI.t()) :: [Definition.t()]
  def installed_definitions(%URI{scheme: "session"} = session_uri) do
    workspace = Ezagent.URI.workspace_of(session_uri)

    session_uri
    |> ConfigStore.list_keys_for_subject()
    |> Enum.filter(&String.starts_with?(&1, @install_key_prefix))
    |> Enum.flat_map(fn key ->
      case ConfigStore.resolve(@install_layer, workspace, session_uri, key) do
        {:ok, %ConfigObject{} = install_object} ->
          install_object
          |> installed_definition()
          |> List.wrap()

        :none ->
          []
      end
    end)
  end

  def installed_definitions(_), do: []

  defp retract_session_install(
         %URI{scheme: "session"} = session_uri,
         workspace_uri,
         @install_key_prefix <> ref = key,
         actor_uri
       ) do
    case ConfigStore.resolve(@install_layer, workspace_uri, session_uri, key) do
      {:ok, %ConfigObject{body: %{"removed" => true}} = object} ->
        {:ok, object}

      {:ok, %ConfigObject{}} ->
        ConfigStore.write_and_point(%{
          layer: @install_layer,
          workspace_uri: workspace_uri,
          subject_uri: session_uri,
          key: key,
          body: %{
            ref: ref,
            removed: true
          },
          actor_uri: actor_uri,
          source_turn_id: unique_source_turn_id("socialware-install-retract", session_uri, ref)
        })
        |> case do
          {:ok, %{object: object}} -> {:ok, object}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        :ok
    end
  end

  defp installed_definition(%ConfigObject{body: body}) do
    with config_id when is_binary(config_id) <- Map.get(body, "definition_config_id"),
         {:ok, %ConfigObject{} = object} <- ConfigStore.fetch_object(config_id),
         {:ok, %Definition{} = definition} <- Definition.new(object.body) do
      definition
    else
      _ -> nil
    end
  end

  defp supervised?(%Definition{visibility_policy: policy}) do
    Map.get(policy, :publish_policy, :auto) == :supervised
  end

  defp seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
    ref = install.ref

    # Install seeding is idempotent on the (session, ref) INSTALL identity. The
    # install pointer id is per (session, ref), so a pre-existing pointer is
    # ALWAYS a prior install of THIS ref — never a two-plugins-one-name clash
    # (that hazard, which the shared seed's divergent-body collision guard
    # exists for, only arises at the def/role layer where a name can be
    # double-claimed). Because `seed_install` uses a DETERMINISTIC
    # `source_turn_id`, that guard would otherwise misfire the moment a re-seed's
    # baked body differs from the stored one — e.g. after P0 added
    # `definition_content_hash` to the body (a pre-P0 pointer lacks it), or when
    # a fresh freeze pins a newer revision. Both are the SAME install of the SAME
    # def, not a collision. Re-seeding an already-installed ref is therefore a
    # no-op that HOLDS the frozen revision (freeze-pin §4): only the explicit
    # `repoint_template_installs/4` upgrade path advances a running install.
    case install_state(session_uri, ref) do
      :installed ->
        {:ok, :exists}

      :removed ->
        point_session_install(session_uri, workspace_uri, install, definition, object, actor_uri)

      :none ->
        do_seed_install(session_uri, workspace_uri, definition, object, install, actor_uri)
    end
  end

  defp install_state(%URI{scheme: "session"} = session_uri, ref) when is_binary(ref) do
    workspace = Ezagent.URI.workspace_of(session_uri)

    case ConfigStore.resolve(@install_layer, workspace, session_uri, install_key(ref)) do
      {:ok, %ConfigObject{body: %{"removed" => true}}} -> :removed
      {:ok, %ConfigObject{}} -> :installed
      :none -> :none
    end
  end

  defp do_seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
    ref = install.ref

    ConfigStore.seed_object_if_no_pointer(%{
      layer: @install_layer,
      workspace_uri: workspace_uri,
      subject_uri: session_uri,
      key: install_key(ref),
      body: install_body(ref, install.config, definition, object),
      actor_uri: actor_uri,
      source_turn_id: "socialware-install:#{URI.to_string(session_uri)}:#{ref}",
      collision_tag:
        {:socialware_install_collision, URI.to_string(session_uri), ref, definition.name}
    })
  end

  defp install_body(ref, config, %Definition{} = _definition, %ConfigObject{} = object) do
    %{
      ref: ref,
      seed_config: config,
      definition_subject_uri: object.subject_uri,
      definition_config_id: object.id,
      # §4.3 — the durable audit/grandfathering copy of the env-independent hash
      # alongside the pinned revision id.
      definition_content_hash: object.content_hash
    }
  end

  defp resolve_definitions(installs, workspace_uri, opts \\ []) do
    lookup_fun = Keyword.get(opts, :lookup_fun, &DefinitionRegistry.lookup/2)

    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case resolve_install(install, workspace_uri, lookup_fun) do
        {:ok, definition, object} -> {:cont, {:ok, [{definition, object, install} | acc]}}
        :error -> {:halt, {:error, {:unknown_socialware_install, install.ref}}}
      end
    end)
    |> case do
      {:ok, defs} -> {:ok, Enum.reverse(defs)}
      error -> error
    end
  end

  # Pin-honoring resolution (SPEC §4.2 item 2): a frozen `config_id` resolves the
  # EXACT immutable revision via `ConfigStore.fetch_object/1`; only an unpinned
  # (`config_id == nil`) install falls back to the live current-pointer
  # `DefinitionRegistry.lookup/2`.
  defp resolve_install(%{config_id: config_id} = _install, _workspace_uri, _lookup_fun)
       when is_binary(config_id) do
    with {:ok, %ConfigObject{} = object} <- ConfigStore.fetch_object(config_id),
         {:ok, %Definition{} = definition} <- Definition.new(object.body) do
      {:ok, definition, object}
    else
      _ -> :error
    end
  end

  defp resolve_install(install, workspace_uri, lookup_fun) do
    case lookup_fun.(workspace_uri, install.ref) do
      {:ok, definition, object} -> {:ok, definition, object}
      :error -> :error
    end
  end

  # Resolve each install to its current revision and bake the pin into a canonical
  # spec map. An entry already pinned (`config_id != nil`) keeps its pin (§4.1
  # idempotency); a fresh entry records the resolved `object.id` + `content_hash`.
  defp freeze_installs(installs, workspace_uri) do
    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case resolve_install(install, workspace_uri, &DefinitionRegistry.lookup/2) do
        {:ok, _definition, %ConfigObject{} = object} ->
          frozen = %{
            ref: install.ref,
            config: install.config,
            config_id: install.config_id || object.id,
            content_hash:
              install.content_hash || object.content_hash ||
                Definition.content_hash(object.body)
          }

          {:cont, {:ok, [frozen | acc]}}

        :error ->
          {:halt, {:error, {:unknown_socialware_install, install.ref}}}
      end
    end)
    |> case do
      {:ok, frozen} -> {:ok, Enum.reverse(frozen)}
      error -> error
    end
  end

  # Drop frozen pins back to bare refs so a re-resolve advances to the current
  # published revision (used by the explicit `repoint` upgrade path).
  defp strip_install_pins(content) do
    case parsed_installs_from_template(content) do
      {:ok, installs} -> put_installs(content, Enum.map(installs, & &1.ref))
      {:error, _} -> content
    end
  end

  # Write the frozen install specs back into the template content, preserving
  # whichever key form (`:installs` / `"installs"`) the content already used.
  defp put_installs(content, frozen) do
    cond do
      Map.has_key?(content, :installs) -> Map.put(content, :installs, frozen)
      Map.has_key?(content, "installs") -> Map.put(content, "installs", frozen)
      true -> Map.put(content, :installs, frozen)
    end
  end

  defp parse_installs(installs) when is_list(installs) do
    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case parse_install(install) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_install(ref) when is_binary(ref) and ref != "",
    do: {:ok, %{ref: ref, config: %{}, config_id: nil, content_hash: nil}}

  defp parse_install(ref) when is_atom(ref) and not is_nil(ref) and not is_boolean(ref),
    do: {:ok, %{ref: Atom.to_string(ref), config: %{}, config_id: nil, content_hash: nil}}

  defp parse_install({ref, config}) when is_map(config) do
    with {:ok, parsed} <- parse_install(ref) do
      {:ok, %{parsed | config: config}}
    end
  end

  defp parse_install(install) when is_map(install) do
    ref =
      Map.get(install, :ref) || Map.get(install, "ref") || Map.get(install, :name) ||
        Map.get(install, "name")

    config = Map.get(install, :config) || Map.get(install, "config") || %{}
    # The frozen pin travels string-keyed once the template content round-trips
    # through JSON persistence (§4.4) — read both key forms so the pin never
    # silently drops back to a live lookup.
    config_id = Map.get(install, :config_id) || Map.get(install, "config_id")
    content_hash = Map.get(install, :content_hash) || Map.get(install, "content_hash")

    with {:ok, parsed} <- parse_install(ref),
         true <- is_map(config) do
      {:ok, %{parsed | config: config, config_id: config_id, content_hash: content_hash}}
    else
      _ -> {:error, {:invalid_socialware_install, install}}
    end
  end

  defp parse_install(other), do: {:error, {:invalid_socialware_install, other}}

  defp install_key(ref), do: @install_key_prefix <> ref

  defp unique_source_turn_id(prefix, %URI{} = session_uri, ref) do
    "#{prefix}:#{URI.to_string(session_uri)}:#{ref}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
