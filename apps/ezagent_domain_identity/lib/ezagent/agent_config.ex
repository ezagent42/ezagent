defmodule Ezagent.AgentConfig do
  @moduledoc """
  Console-facing facade for runtime agent config cascade reads and mutations.

  The durable mutation owner remains `Ezagent.Behavior.ConfigEvolve`; this
  module gives UI/domain callers one stable boundary for reading cascade state
  and dispatching manage-cap-gated writes.
  """

  alias Ezagent.{Invocation, Socialware.ConfigStore}

  @default_key "advisor.behavior"
  @layer_order ~w(workspace user session)
  @editable_layer "user"

  @type principal_caps :: MapSet.t() | [term()]

  @doc """
  Reads the editable config cascade for an agent.

  The read is gated by the agent's manage-cap — SYMMETRIC with the writes — by
  routing through the `config_evolve.read_cascade` action via `Invocation`.
  Authorization is enforced on the AUTHENTICATED `caller`'s `caps` against the
  target agent (dispatch step-5.5), NOT derived from the target uri: a caller
  without the agent's manage-cap gets `{:error, :unauthorized}`.

  The returned shape is stable for empty agents: it always includes the default
  `advisor.behavior` key plus any dynamic keys currently present in
  `ConfigPointer` rows for the agent.
  """
  @spec read_cascade(
          URI.t() | String.t(),
          URI.t() | String.t(),
          principal_caps(),
          keyword() | map()
        ) ::
          {:ok, map()} | {:error, term()}
  def read_cascade(agent_uri, caller, caps, opts \\ []) do
    with {:ok, agent_uri} <- normalize_agent_uri(agent_uri),
         {:ok, caller} <- normalize_uri(caller),
         %URI{} <- Ezagent.URI.workspace_of(agent_uri) do
      args = read_args(opts)

      agent_uri
      |> action_uri(:read_cascade)
      |> dispatch(:call, args, caller, caps)
      |> case do
        {:ok, %{cascade: cascade}} -> {:ok, cascade}
        {:error, _reason} = error -> error
      end
    else
      :any -> {:error, :invalid_agent_uri}
      {:error, _reason} = error -> error
    end
  end

  @spec read_key(
          URI.t() | String.t(),
          String.t(),
          URI.t() | String.t(),
          principal_caps(),
          keyword() | map()
        ) ::
          {:ok, map()} | {:error, term()}
  @doc """
  Reads one config key from the agent cascade.

  Delegates to the manage-cap-gated `read_cascade/4`, so the same authorization
  applies: a caller without the agent's manage-cap gets `{:error, :unauthorized}`.
  """
  def read_key(agent_uri, key, caller, caps, opts \\ []) when is_binary(key) do
    opts = put_opt(opts, :keys, [key])

    with {:ok, %{keys: [state]}} <- read_cascade(agent_uri, caller, caps, opts) do
      {:ok, state}
    end
  end

  @spec apply_delta(URI.t() | String.t(), URI.t() | String.t(), principal_caps(), map()) ::
          {:ok, map()} | {:error, term()}
  @doc """
  Applies a shallow config patch through `ConfigEvolve`.

  The write is dispatched to the target agent and uses the existing manage-cap
  gate, idempotent turn handling, and append-only config object semantics.
  """
  def apply_delta(agent_uri, caller, caps, attrs) when is_map(attrs) do
    with {:ok, agent_uri} <- normalize_agent_uri(agent_uri),
         {:ok, caller} <- normalize_uri(caller),
         {:ok, args} <- apply_args(agent_uri, attrs) do
      dispatch_apply(agent_uri, caller, caps, args)
    end
  end

  @spec delete_path(URI.t() | String.t(), URI.t() | String.t(), principal_caps(), map()) ::
          {:ok, map()} | {:error, term()}
  @doc """
  Deletes a field path from one config layer/key body.

  This is a versioned replacement of the selected config body. It advances the
  pointer to a new `ConfigObject` and keeps the previous object available for
  history and rollback.
  """
  def delete_path(agent_uri, caller, caps, attrs) when is_map(attrs) do
    with {:ok, agent_uri} <- normalize_agent_uri(agent_uri),
         {:ok, caller} <- normalize_uri(caller),
         {:ok, layer} <- layer(attrs),
         {:ok, key} <- key(attrs),
         {:ok, path} <- path(attrs),
         {:ok, body} <- layer_body(agent_uri, layer, key),
         {:ok, updated_body} <- delete_in_body(body, path),
         {:ok, args} <-
           apply_args(agent_uri, %{
             layer: layer,
             key: key,
             replace_body: updated_body,
             turn_id: field(attrs, :turn_id) || console_turn_id()
           }) do
      dispatch_apply(agent_uri, caller, caps, args)
    end
  end

  @spec repoint(URI.t() | String.t(), URI.t() | String.t(), principal_caps(), map()) ::
          {:ok, map()} | {:error, term()}
  @doc """
  Repoints one `{layer, key}` pointer to an existing config object.
  """
  def repoint(agent_uri, caller, caps, attrs) when is_map(attrs) do
    with {:ok, agent_uri} <- normalize_agent_uri(agent_uri),
         {:ok, caller} <- normalize_uri(caller),
         {:ok, layer} <- layer(attrs),
         {:ok, key} <- key(attrs),
         {:ok, config_id} <- required_string(attrs, :config_id),
         %URI{} = workspace_uri <- Ezagent.URI.workspace_of(agent_uri) do
      args = %{
        layer: layer_atom(layer),
        workspace_uri: workspace_uri,
        subject_uri: agent_uri,
        key: key,
        config_id: config_id
      }

      agent_uri
      |> action_uri(:repoint_config)
      |> dispatch(:call, args, caller, caps)
      |> normalize_mutation_reply(agent_uri, layer, key)
    else
      :any -> {:error, :invalid_agent_uri}
      {:error, _reason} = error -> error
    end
  end

  # Build the `read_cascade` dispatch args from facade opts. Only forward an
  # explicit `:keys` filter; an absent filter lets the action read all keys.
  defp read_args(opts) do
    case opt(opts, :keys, nil) do
      keys when is_list(keys) -> %{keys: Enum.map(keys, &to_string/1)}
      _ -> %{}
    end
  end

  defp apply_args(agent_uri, attrs) do
    with {:ok, layer} <- layer(attrs),
         {:ok, key} <- key(attrs),
         {:ok, patch} <- patch_or_replacement(attrs),
         %URI{} = workspace_uri <- Ezagent.URI.workspace_of(agent_uri) do
      args =
        %{
          turn_id: field(attrs, :turn_id) || console_turn_id(),
          layer: layer_atom(layer),
          workspace_uri: workspace_uri,
          subject_uri: agent_uri,
          key: key
        }
        |> Map.merge(patch)

      {:ok, args}
    else
      :any -> {:error, :invalid_agent_uri}
      {:error, _reason} = error -> error
    end
  end

  defp patch_or_replacement(attrs) do
    case field(attrs, :replace_body) do
      %{} = body ->
        {:ok, %{replace_body: body}}

      nil ->
        case field(attrs, :patch) do
          %{} = patch -> {:ok, %{patch: patch}}
          nil -> {:ok, %{patch: %{}}}
          _ -> {:error, :invalid_patch}
        end

      _ ->
        {:error, :invalid_replace_body}
    end
  end

  defp dispatch_apply(agent_uri, caller, caps, args) do
    agent_uri
    |> action_uri(:apply_config_delta)
    |> dispatch(:call, args, caller, caps)
    |> normalize_mutation_reply(agent_uri, to_string(args.layer), args.key)
  end

  defp normalize_mutation_reply({:ok, reply}, agent_uri, layer, key) when is_map(reply) do
    {:ok,
     %{
       agent_uri: URI.to_string(agent_uri),
       layer: layer,
       key: key,
       config_id: Map.get(reply, :config_id),
       previous_config_id: Map.get(reply, :previous_config_id)
     }}
  end

  defp normalize_mutation_reply({:error, _reason} = error, _agent_uri, _layer, _key), do: error

  defp dispatch(target, mode, args, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: target,
      mode: mode,
      args: args,
      ctx: %{caller: caller, caps: normalize_caps(caps), reply: {:caller_inbox, self()}}
    })
  end

  defp action_uri(agent_uri, action) do
    Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=config_evolve.#{action}")
  end

  defp layer_body(agent_uri, layer, key) do
    case ConfigStore.layer_objects_for_key(agent_uri, key)[layer] do
      %{object: %{body: %{} = body}} -> {:ok, body}
      nil -> {:error, :config_not_found}
    end
  end

  defp delete_in_body(body, path) do
    case do_delete_in_body(body, path) do
      {:ok, updated} -> {:ok, updated}
      :error -> {:error, :path_not_found}
    end
  end

  defp do_delete_in_body(body, [key]) when is_map(body) do
    if Map.has_key?(body, key), do: {:ok, Map.delete(body, key)}, else: :error
  end

  defp do_delete_in_body(body, [key | rest]) when is_map(body) do
    case Map.get(body, key) do
      %{} = nested ->
        case do_delete_in_body(nested, rest) do
          {:ok, updated_nested} -> {:ok, Map.put(body, key, updated_nested)}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp do_delete_in_body(_body, _path), do: :error

  defp layer(attrs) do
    case field(attrs, :layer) || @editable_layer do
      layer when layer in @layer_order -> {:ok, layer}
      layer when is_atom(layer) -> layer(%{layer: Atom.to_string(layer)})
      _ -> {:error, :invalid_layer}
    end
  end

  defp key(attrs), do: required_string(attrs, :key, @default_key, :invalid_key)

  defp path(attrs) do
    case field(attrs, :path) do
      [_ | _] = path ->
        if Enum.all?(path, &(is_binary(&1) or is_atom(&1))),
          do: {:ok, Enum.map(path, &to_string/1)},
          else: {:error, :invalid_path}

      _ ->
        {:error, :invalid_path}
    end
  end

  defp required_string(attrs, key, default \\ nil, error \\ :invalid_key) do
    case field(attrs, key) || default do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp normalize_agent_uri(uri) do
    with {:ok, %URI{} = uri} <- normalize_uri(uri),
         {:ok, "agent"} <- Ezagent.URI.type(uri) do
      {:ok, uri}
    else
      {:ok, _other} -> {:error, :invalid_agent_uri}
      :error -> {:error, :invalid_agent_uri}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_uri(%URI{} = uri), do: {:ok, uri}

  defp normalize_uri(uri) when is_binary(uri) and uri != "" do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_uri}
    end
  end

  defp normalize_uri(_), do: {:error, :invalid_uri}

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(opts, key, default) when is_map(opts), do: field(opts, key) || default

  defp put_opt(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp put_opt(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)

  defp normalize_caps(%MapSet{} = caps), do: caps
  defp normalize_caps(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps(_), do: MapSet.new()

  defp layer_atom("workspace"), do: :workspace
  defp layer_atom("user"), do: :user
  defp layer_atom("session"), do: :session

  defp console_turn_id, do: "console:" <> Ecto.UUID.generate()
end
