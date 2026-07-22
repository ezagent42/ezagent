defmodule Ezagent.ActionSet.Session.SelfAdd do
  @moduledoc """
  Cap-gated writer for the derived `:members` projection.

  `:add_self` is exempt from the generic dispatch cap list because the handler
  must ignore caller-presented `ctx.caps`. It binds the subject to the explicit
  authenticated principal, loads that principal's held caps independently, and
  routes the tier-1 check through the unified generation-aware authorization
  predicate before writing any projection state.
  """

  alias Ezagent.ActionSet.Session.{Members, SelfAdd.Effects}

  @spec handle_add_self(map(), map(), module()) ::
          {:ok, %{status: :added | :already_member}, [term()]}
          | {:error,
             :unauthorized
             | {:member_not_registered, URI.t()}
             | {:role_name_taken, String.t()}}
  def handle_add_self(
        %{member: %URI{} = subject, facets: facets},
        %{authenticated_principal: %URI{} = holder} = ctx,
        source_module
      )
      when is_map(facets) do
    if same_principal?(subject, holder) do
      authorize_and_add(holder, Members.sanitize_facets(facets), ctx, source_module)
    else
      {:error, :unauthorized}
    end
  end

  def handle_add_self(_args, _ctx, _source_module), do: {:error, :unauthorized}

  defp authorize_and_add(holder, facets, ctx, source_module) do
    session_uri = ctx[:self_uri]
    held = holder |> Ezagent.Identity.read_held_caps() |> Enum.to_list()

    if Ezagent.Session.MemberReceive.holds_member_cap_over?(holder, held, session_uri) do
      add_projection(holder, facets, ctx, source_module)
    else
      {:error, :unauthorized}
    end
  end

  defp add_projection(holder, facets, ctx, source_module) do
    members = ctx[:read].(:members, %{})
    join_facets = ctx[:read].(:join_facets, %{})
    effective_facets = Map.merge(facets, Map.get(join_facets, holder, %{}))

    case Members.role_name_conflict(members, holder, Map.get(effective_facets, :role_name)) do
      {:error, _} = error ->
        error

      :ok ->
        case Map.get(members, holder) do
          %{online: true} ->
            {:ok, %{status: :already_member}, []}

          _missing_or_offline ->
            case Ezagent.KindRegistry.lookup(holder) do
              {:ok, member_pid} ->
                {_members, effects} =
                  Effects.on_add(holder, member_pid, effective_facets, ctx, source_module)

                {:ok, %{status: :added}, effects}

              :error ->
                {:error, {:member_not_registered, holder}}
            end
        end
    end
  end

  defp same_principal?(left, right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end
end
