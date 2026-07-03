defmodule Ezagent.Socialware.DefinitionRegistry do
  @moduledoc """
  ConfigStore-backed resolver for socialware definitions.

  Definitions live under the structured non-URI ConfigStore subject
  `socialware:<name>` with ConfigObject key `"socialware"`, mirroring recipe
  storage's `recipe:<name>` subject. Workspace is a SEPARATE ConfigStore field,
  so it is not embedded in the subject (T1 project B).
  """

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ConfigObject, ConfigStore, Definition}

  @definition_key "socialware"
  @definition_layer "workspace"

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

  @doc "Seed the built-in chat and socialware definitions if absent or stale."
  @spec seed_builtin_definitions() :: :ok | {:error, term()}
  def seed_builtin_definitions do
    Enum.reduce_while(builtin_definitions(), :ok, fn definition, :ok ->
      case seed_builtin_definition(definition, workspace_uri: system_workspace_uri()) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
        source_turn_id: "socialware-definition-seed:#{workspace_uri}:#{definition.name}",
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
      {:ok, object} ->
        {:ok, object}

      :none when ws != system_ws ->
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

      :none ->
        public_object(name)
    end
  end

  defp public_object(name) do
    @definition_layer
    |> ConfigStore.list_current_objects(@definition_key)
    |> Enum.find(fn %ConfigObject{subject_uri: subject} = object ->
      subject == definition_subject_uri(object.workspace_uri, name) and public_object?(object)
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
         true <- visible_to_workspace?(definition, object.workspace_uri, caller_ws, system_ws) do
      [
        %{
          name: definition.name,
          version: definition.version,
          title: definition.title || definition.name,
          description: definition.description || "",
          public?: public?(definition),
          workspace_uri: object.workspace_uri
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

  defp seed_builtin_definition(%Definition{} = definition, opts) do
    workspace_uri = opts |> Keyword.fetch!(:workspace_uri) |> uri_string()
    subject = definition_subject_uri(workspace_uri, definition.name)
    body = Definition.body(definition)
    normalized_body = json_normalize(body)

    case ConfigStore.resolve(@definition_layer, workspace_uri, subject, @definition_key) do
      :none ->
        seed_definition_if_absent(definition, workspace_uri: workspace_uri)

      {:ok, %ConfigObject{body: ^normalized_body}} ->
        {:ok, :exists}

      {:ok, %ConfigObject{} = object} ->
        if builtin_seed_object?(object) do
          write_definition(definition,
            workspace_uri: workspace_uri,
            actor_uri: default_seed_actor(),
            caller_workspace_uri: workspace_uri,
            authority: :system_seed,
            source_turn_id: builtin_upgrade_source_turn_id(workspace_uri, definition.name, body)
          )
          |> case do
            {:ok, _object} -> {:ok, :seeded}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, :exists}
        end
    end
  end

  defp builtin_seed_object?(%ConfigObject{source_turn_id: source_turn_id})
       when is_binary(source_turn_id) do
    String.starts_with?(source_turn_id, [
      "socialware-definition-seed:",
      "socialware-definition-seed-upgrade:"
    ])
  end

  defp builtin_seed_object?(_), do: false

  defp default_seed_actor, do: Ezagent.URI.user(:system, :admin) |> URI.to_string()

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri

  defp json_normalize(body) do
    body
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp builtin_upgrade_source_turn_id(workspace_uri, name, body) do
    hash =
      body
      |> json_normalize()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "socialware-definition-seed-upgrade:#{workspace_uri}:#{name}:#{hash}"
  end

  defp unique_source_turn_id(workspace_uri, name) do
    "socialware-definition-write:#{workspace_uri}:#{name}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
