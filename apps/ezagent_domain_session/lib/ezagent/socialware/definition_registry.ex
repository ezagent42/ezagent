defmodule Ezagent.Socialware.DefinitionRegistry do
  @moduledoc """
  ConfigStore-backed resolver for socialware definitions.

  Definitions live at `config://<workspace>/socialware/<name>` with ConfigObject
  key `"socialware"`, mirroring role-as-data's `config://.../role/...` pattern.
  """

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ConfigObject, ConfigStore, Definition}

  @definition_key "socialware"
  @definition_layer "workspace"

  @doc "The fixed ConfigObject key for socialware definition bodies."
  @spec definition_key() :: String.t()
  def definition_key, do: @definition_key

  @doc "Return the opaque ConfigStore subject URI for a workspace socialware name."
  @spec definition_subject_uri(String.t() | URI.t(), String.t()) :: String.t()
  def definition_subject_uri(workspace_uri, name)
      when is_binary(name) and name != "" do
    workspace =
      workspace_uri
      |> uri_string()
      |> Ezagent.URI.new!()
      |> Ezagent.URI.workspace_name!()

    "config://#{workspace}/socialware/#{name}"
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

  @doc "Seed the built-in chat and socialware definitions if absent."
  @spec seed_builtin_definitions() :: :ok | {:error, term()}
  def seed_builtin_definitions do
    Enum.reduce_while(builtin_definitions(), :ok, fn definition, :ok ->
      case seed_definition_if_absent(definition, workspace_uri: system_workspace_uri()) do
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
          Ezagent.Behavior.Session,
          Ezagent.Behavior.Publisher.SessionImpl
        ],
        shape: [
          Ezagent.Behavior.Turn,
          Ezagent.Behavior.Surface
        ],
        adapters: [%{adapter_id: "web_feed", role: :customer, config: %{}}],
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
          :none -> :error
        end

      :none ->
        :error
    end
  end

  defp normalize_definition(%Definition{} = definition), do: {:ok, definition}
  defp normalize_definition(attrs) when is_map(attrs), do: Definition.new(attrs)

  defp default_seed_actor, do: Ezagent.URI.user(:system, :admin) |> URI.to_string()

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
