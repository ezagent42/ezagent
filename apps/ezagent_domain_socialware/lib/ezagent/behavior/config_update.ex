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
    # #607 codex CRITICAL — OBJECT-KEYED, so apply_delta is ATOMIC-by-ordering
    # across the two durable stores with no shared transaction (spec section 7.4:
    # repoint the agent's high cascade layer "at it" — the new IMMUTABLE config
    # object). The agent's user cascade layer URI names a SPECIFIC immutable
    # object (`ConfigProjection.object_uri/2`), NOT the mutable pointer. The
    # three steps are ordered so no single-step failure leaves harmful
    # uncompensated state:
    #
    #   1. `ConfigStore.write_config` — write the immutable object (fallible,
    #      atomic within itself). On failure NOTHING else has happened.
    #   2. repoint the agent's user cascade layer at the NEW OBJECT's URI. The
    #      object already exists + is immutable, so the layer can never resolve
    #      stale/:none. On failure the object is an orphan (unreferenced row in an
    #      append-only store) and NO pointer moved — non-harmful; a retry writes a
    #      new object and repoints again.
    #   3. `ConfigStore.put_pointer` — current+previous bookkeeping for rollback,
    #      LAST. On failure the agent is already correctly repointed to the new
    #      object (the consume is real); only the rollback-target bookkeeping is
    #      stale — non-harmful (a fresh apply_delta re-establishes it).
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
         {:ok, object} <- ConfigStore.write_config(Map.put(attrs, :body, body)),
         {:ok, repoint_status} <- repoint_agent_layer(attrs, object.id),
         {:ok, %{previous_config_id: previous}} <-
           ConfigStore.put_pointer(Map.put(attrs, :config_id, object.id)) do
      applied = ctx.read.(:applied, %{})

      reply = %{
        config_id: object.id,
        previous_config_id: previous,
        repoint_status: repoint_status
      }

      {:ok, reply, [{:set, :applied, Map.put(applied, turn_id, reply)}]}
    end
  end

  # #607 — consume seam: repoint the subject agent's #17 high (user) cascade layer
  # at the IMMUTABLE config object's stable resource URI, so the next spawn
  # re-materializes the new soul. `subject_uri` IS the target agent.
  #
  # `CascadeRepoint.repoint_user_layer/3` writes the object URI into the agent's
  # DURABLE spawn source (its Sandbox `respawn_template_data.cascade_resolution`,
  # snapshot-persisted), so a cold next-spawn resolves it — this is what makes
  # the consume real, not write-only (#607 codex HIGH). The sandbox read/write
  # runs under `system://agent-internal` (the user's caps already gated the
  # action; the sandbox effect is agent-internal). Success -> `:repointed`.
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
  defp repoint_agent_layer(attrs, object_id) do
    case CascadeRepoint.repoint_user_layer(
           attrs.subject_uri,
           attrs.workspace_uri,
           object_id
         ) do
      :ok -> {:ok, :repointed}
      {:error, _reason} = err -> err
    end
  end

  @spec handle_repoint(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_repoint(args, ctx) do
    # Rollback / explicit advance: repoint the agent's user cascade layer at the
    # TARGET immutable object (`config_id`), then update the pointer bookkeeping.
    # Same object-keyed ordering as apply_delta: the target object already exists
    # + is immutable, so the layer can never resolve stale; the bookkeeping write
    # is LAST so a failure there leaves the agent correctly repointed.
    attrs = %{
      layer: Map.fetch!(args, :layer),
      workspace_uri: Map.fetch!(args, :workspace_uri),
      subject_uri: Map.fetch!(args, :subject_uri),
      key: Map.fetch!(args, :key),
      config_id: Map.fetch!(args, :config_id),
      actor_uri: ctx.caller,
      source_turn_id: "repoint:#{URI.to_string(ctx.self_uri)}"
    }

    with {:ok, :repointed} <- repoint_agent_layer(attrs, attrs.config_id),
         {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(attrs) do
      {:ok, %{config_id: attrs.config_id, previous_config_id: previous}, []}
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
