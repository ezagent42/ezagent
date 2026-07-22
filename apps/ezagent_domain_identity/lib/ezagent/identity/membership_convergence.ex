defmodule Ezagent.Identity.MembershipConvergence do
  @moduledoc """
  Self-driven convergence from durable tier-1 membership caps to session roster
  projections.

  The identity domain recognizes the cap by fields and dispatches the Session
  action by URI/action string; it deliberately has no compile-time dependency on
  the session action-set module. Writes are cast-only and the Session handler
  independently rechecks the authenticated holder's durable cap.
  """

  alias Ezagent.{Capability, Cmd, Invocation}

  @telemetry_event [:ezagent, :identity, :membership_convergence, :dispatch]

  @spec converge(URI.t(), Enumerable.t()) :: :ok
  def converge(%URI{} = entity_uri, held_caps) do
    entity_uri
    |> pending_sessions(held_caps)
    |> Enum.each(&cast_add_self(&1, entity_uri))

    :ok
  end

  @doc false
  @spec after_commit_effects(URI.t(), Enumerable.t()) :: [term()]
  def after_commit_effects(%URI{} = entity_uri, held_caps) do
    entity_uri
    |> pending_sessions(held_caps)
    |> Enum.map(fn session_uri ->
      emit_dispatch(entity_uri, session_uri)
      {:dispatch_after_commit, add_self_cmd(session_uri, entity_uri)}
    end)
  end

  def after_commit_effects(_entity_uri, _held_caps), do: []

  defp pending_sessions(entity_uri, held_caps) do
    held_caps
    |> Enum.filter(&membership_cap?/1)
    |> Enum.map(fn cap -> Ezagent.URI.instance(cap.instance) end)
    |> Enum.uniq_by(&Ezagent.URI.stable_key/1)
    |> Enum.filter(&projection_missing?(&1, entity_uri))
  rescue
    _ -> []
  end

  defp membership_cap?(%Capability{kind: :session, instance: %URI{}} = cap) do
    Capability.granted_by_entity?(cap) and Capability.action_of(cap) == :receive
  end

  defp membership_cap?(_cap), do: false

  defp projection_missing?(session_uri, entity_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} when is_map(slice) ->
        not (slice
             |> Ezagent.Kind.normalize_slice_view()
             |> Map.get(:members, %{})
             |> Map.has_key?(entity_uri))

      _ ->
        # A session that is absent/not-ready cannot accept the cast. Its own
        # load-time reconciliation is the durable backstop; avoid a noisy,
        # guaranteed-to-fail fast-path dispatch here.
        false
    end
  rescue
    _ -> false
  end

  defp cast_add_self(session_uri, entity_uri) do
    emit_dispatch(entity_uri, session_uri)

    _ =
      Invocation.dispatch(%Invocation{
        target: action_target(session_uri),
        mode: :cast,
        args: %{member: entity_uri, facets: %{}},
        ctx: dispatch_ctx(entity_uri),
        origin: :trusted_internal
      })

    :ok
  end

  defp add_self_cmd(session_uri, entity_uri) do
    %Cmd{
      target: Ezagent.URI.instance(session_uri),
      action: :add_self,
      args: %{member: entity_uri, facets: %{}},
      ctx: dispatch_ctx(entity_uri),
      origin: :trusted_internal
    }
  end

  defp dispatch_ctx(entity_uri) do
    %{
      caller: entity_uri,
      authenticated_principal: entity_uri,
      caps: MapSet.new(),
      reply: :ignore
    }
  end

  # Keep the domain edge encoded as an action URI rather than pinning the
  # session-domain action-set module.
  defp action_target(session_uri) do
    Ezagent.URI.new!(
      "#{URI.to_string(Ezagent.URI.instance(session_uri))}?action=session.add_self"
    )
  end

  defp emit_dispatch(entity_uri, session_uri) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{entity_uri: entity_uri, session_uri: session_uri}
    )
  end
end
