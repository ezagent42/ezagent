defmodule Ezagent.Agent.Config do
  @moduledoc """
  Console-facing facade for runtime agent config cascade reads and mutations.

  The durable mutation owner remains `Ezagent.ActionSet.ConfigEvolve`; this
  module gives UI/domain callers one stable boundary for reading cascade state
  and dispatching manage-cap-gated writes.
  """

  alias Ezagent.{Invocation, Socialware.ConfigStore}
  alias Ezagent.ActionSet.ConfigEvolve

  @default_key "agent.soul"
  @layer_order ~w(workspace user session)
  @editable_layer "user"

  @type principal_caps :: MapSet.t() | [term()]

  @doc """
  The default config-cascade key under which every agent's behavior/persona
  config is stored. Its body's `soul_md` field projects to the agent's soul
  file (`CLAUDE.md`) via `Ezagent.Socialware.ConfigProjection.render_soul/1`.

  Exposed as the single canonical source so out-of-app readers (e.g. the world
  console) reference this fn rather than re-hardcoding the literal — killing the
  drift trap where an inlined copy silently points at a stale key.
  """
  @spec default_key() :: String.t()
  def default_key, do: @default_key

  @doc """
  Reads the editable config cascade for an agent.

  The read is gated by the agent's manage-cap — SYMMETRIC with the writes.
  Authorization is enforced on the AUTHENTICATED `caller`'s `caps` against the
  target agent (the SAME `cap(:agent, Manage, :any)` instance-scoped gate the
  `config_evolve.read_cascade` dispatch enforced at step-5.5), NOT derived from
  the target uri: a caller without the agent's manage-cap — including a caller
  holding the manage-cap for a DIFFERENT agent — gets `{:error, :unauthorized}`.

  Unlike the writes, the read does NOT dispatch (which would lazy-spawn /
  force-activate a cold agent — the FP5 S5 `:activate_timeout` bug, #115, where
  the world config DETAIL surface activated a cold cc agent that needs >5s to
  launch claude). After authorizing, it reads the cascade DIRECTLY from the
  durable `ConfigStore` via `Ezagent.ActionSet.ConfigEvolve.build_cascade/2` (a
  pure DB projection — NO process, NO activation). The cap gate is preserved by
  reconstructing the EXACT needed-cap the dispatch path builds (kind `:agent`,
  behavior `Manage`, the target agent instance + workspace) and authorizing it
  the SAME way step-5.5 does, via `Ezagent.Identity.caps_authorize?/2`.

  The returned shape is stable for empty agents: it always includes the default
  `agent.soul` key plus any dynamic keys currently present in
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
         {:ok, holder} <- normalize_uri(caller),
         %URI{} <- Ezagent.URI.workspace_of(agent_uri),
         :ok <- authorize_read_cascade(holder, agent_uri, caps) do
      {:ok, ConfigEvolve.build_cascade(agent_uri, read_keys(opts))}
    else
      :any -> {:error, :invalid_agent_uri}
      {:error, _reason} = error -> error
    end
  end

  # Preserve the manage-cap gate the `config_evolve.read_cascade` dispatch
  # enforced (step-5.5) WITHOUT dispatching. The dispatch built the needed-cap
  # from `ConfigEvolve.required_caps()[:read_cascade]` (== `cap(:agent, Manage,
  # :any)`) and substituted the runtime instance/workspace from the target
  # (runtime.ex:440-477). We rebuild the IDENTICAL needed-cap (pure field
  # assignment) and authorize via the sanctioned chokepoint owner
  # `Ezagent.Identity.caps_authorize?/2` (the same granted-by-entity + cap-match
  # predicate the dispatch uses — the cap-check stays at an allowlisted owner,
  # not hand-rolled here). Instance-scoped: a manage-cap
  # over a DIFFERENT agent does NOT match (its `instance` is that other agent),
  # so cross-agent reads fail closed — the exact discrimination dispatch gave.
  defp authorize_read_cascade(holder, agent_uri, caps) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :read_cascade,
      instance: Ezagent.URI.instance(agent_uri),
      workspace_uri: Ezagent.Capability.workspace_of(agent_uri)
    }

    if Ezagent.Identity.caps_authorize?(holder, caps, needed) do
      :ok
    else
      {:error, :unauthorized}
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

    # `build_cascade/2` ALWAYS appends the `@default_cascade_key`
    # ("agent.soul") to the resolved key set (so the full-cascade
    # `read_config` view always carries the soul key). That means a
    # single-key read whose `key` is NOT the default gets back TWO
    # key-states, and the old `%{keys: [state]}` one-element match
    # silently failed — returning the WHOLE cascade map (no
    # `:effective_body`) to the caller. Select the requested key out of
    # the cascade explicitly instead of assuming arity-1. (#108: this is
    # the deterministic AgentReadTest `KeyError :effective_body`
    # regression — the #943 default-append + #1039 single-key reader
    # were each green alone but red merged.)
    with {:ok, %{keys: states}} <- read_cascade(agent_uri, caller, caps, opts) do
      case Enum.find(states, &(&1.key == key)) do
        %{} = state -> {:ok, state}
        nil -> {:error, :not_found}
      end
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
         :ok <- authorize_mutation(agent_uri, caller, caps, key),
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

  # Build the `keys` filter for `ConfigEvolve.build_cascade/2` from facade opts.
  # Only forward an explicit `:keys` filter (as strings); an absent filter is
  # `nil`, which `build_cascade/2` reads as "all subject keys".
  defp read_keys(opts) do
    case opt(opts, :keys, nil) do
      keys when is_list(keys) -> Enum.map(keys, &to_string/1)
      _ -> nil
    end
  end

  defp apply_args(agent_uri, attrs) do
    with {:ok, layer} <- layer(attrs),
         {:ok, key} <- key(attrs),
         {:ok, turn_id} <- turn_id(attrs),
         {:ok, patch} <- patch_or_replacement(attrs),
         %URI{} = workspace_uri <- Ezagent.URI.workspace_of(agent_uri) do
      args =
        %{
          turn_id: turn_id,
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
      ctx: %{caller: caller, caps: normalize_caps(caps), reply: {:caller_inbox, self()}},
      origin: :trusted_internal
    })
  end

  defp action_uri(agent_uri, action) do
    Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=config_evolve.#{action}")
  end

  # Authorization preflight for `delete_path` BEFORE any existence-revealing read.
  #
  # `delete_path` is read-modify-write at the facade: it reads the current body
  # (`layer_body`) and computes the deletion (`delete_in_body`) before the gated
  # `apply_config_delta` dispatch. Without this preflight, a caller lacking the
  # manage-cap would get `:config_not_found` / `:path_not_found` from those reads
  # — an existence oracle (the #958 info-leak) — instead of `:unauthorized`.
  #
  # `read_cascade` is gated on the SAME cap the mutation needs — `cap(:agent,
  # Manage, :any)` (see `Ezagent.ActionSet.ConfigEvolve.required_caps/0`, where
  # `apply_config_delta` and `read_cascade` are defined together) — and the
  # dispatch gate rejects an unauthorized caller BEFORE its handler reads. So
  # probing it here authorizes via the real gate (no divergent cap check) and an
  # unauthorized caller fails closed with `:unauthorized`, learning nothing about
  # what exists. An authorized caller passes regardless of existence, so the
  # precise `:config_not_found` / `:path_not_found` error is preserved for them.
  defp authorize_mutation(agent_uri, caller, caps, key) do
    case read_cascade(agent_uri, caller, caps, keys: [key]) do
      {:ok, _cascade} -> :ok
      {:error, _reason} = error -> error
    end
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

  # RESERVED-PREFIX GUARD — the facade accepts a caller-supplied `turn_id`. The
  # `cr-stage:`/`cr-publish:` prefixes are CR-owned `source_turn_id` namespaces;
  # reject them on the NORMAL apply/delete path so a caller cannot route a CR
  # marker through the non-CR facade and spoof an idempotency early-return /
  # settled-turn provenance (SPEC §4.2.1). A `nil` turn_id mints a console one.
  defp turn_id(attrs) do
    case field(attrs, :turn_id) do
      nil ->
        {:ok, console_turn_id()}

      turn_id when is_binary(turn_id) ->
        if ConfigStore.reserved_turn_prefix?(turn_id),
          do: {:error, {:reserved_turn_id_prefix, turn_id}},
          else: {:ok, turn_id}

      _ ->
        {:error, :invalid_turn_id}
    end
  end

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
