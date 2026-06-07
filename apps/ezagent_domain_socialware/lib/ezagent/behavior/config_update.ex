defmodule Ezagent.Behavior.ConfigUpdate do
  @moduledoc """
  Applies approved self-evolve config deltas through the socialware turn gate.

  `apply_delta` accepts only a `turn_id`; the delta itself must already be in
  the settled Turn result. This keeps SW-UPD on the same approval path as
  customer-facing turn output.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :config_updates

  alias Ezagent.Socialware.{CascadeRepoint, ConfigStore}

  reads_siblings([:turns])

  action(:apply_delta,
    args: %{turn_id: :string},
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:apply_delta],
    modes: [:call],
    description: "Apply the config delta carried by a settled optimizer turn"
  )

  action(:repoint,
    args: %{
      layer: :atom,
      workspace_uri: :uri,
      subject_uri: :uri,
      key: :string,
      config_id: :string
    },
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:repoint],
    modes: [:call],
    description: "Rollback or advance a config pointer to an existing immutable object"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{applied: %{}}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_apply_delta(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_apply_delta(%{turn_id: turn_id}, ctx) do
    # #607 codex CRITICAL — pointer-advance + cascade-repoint must be ATOMIC. The
    # agent's user cascade layer is repointed at the pointer's STABLE resource
    # URI (`ConfigProjection.pointer_uri/4`), which keys the POINTER, not a
    # specific object — so the repoint is INDEPENDENT of which immutable object
    # the pointer points at, and can therefore run BEFORE `write_and_point`.
    # Doing the repoint first means a repoint failure (no cascade_resolution /
    # no_such_actor / authz / write error) returns error WITHOUT ever advancing
    # the mutable config pointer. A later spawn can never consume a config whose
    # repoint was rejected, because the pointer was never moved.
    with {:ok, turn} <- settled_turn(ctx, turn_id),
         {:ok, delta} <- config_delta(turn),
         attrs <- attrs_from_delta(delta, turn_id, ctx),
         body <-
           ConfigStore.merge_delta(
             attrs.layer,
             attrs.workspace_uri,
             attrs.subject_uri,
             attrs.key,
             attrs.patch
           ),
         {:ok, repoint_status} <- repoint_agent_layer(attrs, ctx),
         {:ok, result} <- ConfigStore.write_and_point(Map.put(attrs, :body, body)) do
      applied = ctx.read.(:applied, %{})

      reply = %{
        config_id: result.config_id,
        previous_config_id: result.previous_config_id,
        repoint_status: repoint_status
      }

      {:ok, reply, [{:set, :applied, Map.put(applied, turn_id, reply)}]}
    end
  end

  # #607 — consume seam: repoint the subject agent's #17 high (user) cascade layer
  # at the immutable config pointer's stable resource URI, so the next spawn
  # re-materializes the new soul. `subject_uri` IS the target agent.
  #
  # `CascadeRepoint.repoint_user_layer/6` writes the pointer URI into the agent's
  # DURABLE spawn source (its Sandbox `respawn_template_data.cascade_resolution`,
  # snapshot-persisted), so a cold next-spawn resolves it — this is what makes
  # the consume real, not write-only (#607 codex HIGH). Success → `:repointed`.
  #
  # Every error FAILS LOUD (no silent `:deferred`):
  #
  #   * `:no_cascade_resolution` — the agent has a sandbox but NO
  #     `cascade_resolution` map (a pre-cascade / non-credentialled agent). It
  #     STRUCTURALLY cannot consume a `user_layer_uri`, and inventing one would
  #     diverge from #17's create-time resolution. There is no durable place to
  #     record the pointer, so returning success would be a silent no-op that
  #     falsely reports the config as applied — surface it as an error instead.
  #   * any other dispatch/write error (`:no_such_actor` for a never-spawned
  #     agent, cap denial, write failure) — likewise loud.
  defp repoint_agent_layer(attrs, ctx) do
    case CascadeRepoint.repoint_user_layer(
           attrs.subject_uri,
           attrs.layer,
           attrs.workspace_uri,
           attrs.subject_uri,
           attrs.key,
           ctx
         ) do
      :ok -> {:ok, :repointed}
      {:error, _reason} = err -> err
    end
  end

  @spec handle_repoint(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_repoint(args, ctx) do
    attrs = %{
      layer: Map.fetch!(args, :layer),
      workspace_uri: Map.fetch!(args, :workspace_uri),
      subject_uri: Map.fetch!(args, :subject_uri),
      key: Map.fetch!(args, :key),
      config_id: Map.fetch!(args, :config_id),
      actor_uri: ctx.caller,
      source_turn_id: "repoint:#{URI.to_string(ctx.self_uri)}"
    }

    case ConfigStore.put_pointer(attrs) do
      {:ok, %{previous_config_id: previous}} ->
        {:ok, %{config_id: attrs.config_id, previous_config_id: previous}, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp settled_turn(ctx, turn_id) do
    turns =
      ctx
      |> Map.get(:siblings, %{})
      |> Map.get(:turns, %{})
      |> Map.get(:turns, %{})

    case Map.fetch(turns, turn_id) do
      {:ok, %{status: :settled} = turn} -> {:ok, turn}
      {:ok, %{status: status}} -> {:error, {:turn_not_settled, status}}
      :error -> {:error, :unknown_turn}
    end
  end

  defp config_delta(%{result: %{config_delta: delta}}) when is_map(delta), do: {:ok, delta}
  defp config_delta(_turn), do: {:error, :missing_config_delta}

  defp attrs_from_delta(delta, turn_id, ctx) do
    %{
      layer: Map.get(delta, :layer) || Map.fetch!(delta, "layer"),
      workspace_uri: Map.get(delta, :workspace_uri) || Map.fetch!(delta, "workspace_uri"),
      subject_uri: Map.get(delta, :subject_uri) || Map.fetch!(delta, "subject_uri"),
      key: Map.get(delta, :key) || Map.fetch!(delta, "key"),
      patch: Map.get(delta, :patch) || Map.fetch!(delta, "patch"),
      actor_uri: ctx.caller,
      source_turn_id: turn_id
    }
  end
end
