defmodule Ezagent.ActionSet.Session.SelfAdd.Effects do
  @moduledoc """
  Projection effects shared by legacy `join` and Phase-B `add_self`.

  Monitor installation, last-seen replay, notification, and membership
  broadcasts live with the roster write so every writer has identical lifecycle
  behavior while M-2 remains additive.
  """

  alias Ezagent.ActionSet.Session.{Delivery, Members}

  @doc false
  @spec on_add(URI.t(), pid(), map(), map(), module()) :: {map(), [term()]}
  def on_add(%URI{} = member_uri, member_pid, facets, ctx, source_module)
      when is_pid(member_pid) and is_map(facets) do
    session_uri = ctx[:self_uri]
    members = ctx[:read].(:members, %{})
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})
    join_cursors = ctx[:read].(:join_cursors, %{})
    join_facets = ctx[:read].(:join_facets, %{})
    effective_facets = Map.merge(facets, Map.get(join_facets, member_uri, %{}))

    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    Enum.each(old_refs_for_member, fn {ref, _uri} ->
      # V5 use-side B2: refs now belong to the `EzagentActor.Signal.Monitor`
      # relay, so this demonitor is a no-op for the Kind (it owns no raw
      # monitor). A late `%Signal{kind: :down}` for a dropped ref is ignored
      # by `handle_signal({:DOWN, …})` (the ref is no longer in `:monitors`).
      _ = Process.demonitor(ref, [:flush])
    end)

    # V5 use-side B2 — monitor via the sanctioned relay; the death arrives
    # as `%Signal{kind: :down}` and the Kind.Server envelope clause
    # reconstructs the raw `{:DOWN, ref, :process, pid, reason}` tuple
    # `handle_signal/2` matches. Ref correlation is unchanged.
    {:ok, ref} = EzagentActor.Signal.monitor(member_pid)
    existing_meta = Map.get(members, member_uri, %{})

    joined_cursor =
      Map.get(ctx, :membership_join_cursor, Map.get(join_cursors, member_uri, 0))

    new_members =
      Map.put(
        members,
        member_uri,
        existing_meta
        |> Map.put(:online, true)
        |> Map.put(:joined_cursor, joined_cursor)
        |> Members.put_member_facets(effective_facets)
      )

    new_monitors =
      monitors_without_member
      |> Map.new()
      |> Map.put(ref, member_uri)

    Delivery.replay_messages_after_sequence(session_uri, member_uri, joined_cursor)
    Delivery.replay_messages_since(session_uri, member_uri, last_seen)
    new_last_seen = Map.delete(last_seen, member_uri)

    if user_uri?(member_uri) do
      _ =
        Ezagent.Notifications.notify(member_uri, %{
          type: :session_member_joined,
          body: %{
            text: "You joined session #{URI.to_string(session_uri)}.",
            session_uri: session_uri
          },
          source: source_module
        })
    end

    effects =
      [
        {:set, :members, new_members},
        {:set_transient, :monitors, new_monitors},
        {:set, :last_seen, new_last_seen},
        {:set, :join_facets, Map.delete(join_facets, member_uri)}
      ] ++ Delivery.broadcast_membership_effects(session_uri, {:member_joined, member_uri})

    {new_members, effects}
  end

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false
end
