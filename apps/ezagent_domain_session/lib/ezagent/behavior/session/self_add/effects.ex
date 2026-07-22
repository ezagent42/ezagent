defmodule Ezagent.ActionSet.Session.SelfAdd.Effects do
  @moduledoc """
  Projection effects shared by legacy `join` and Phase-B `add_self`.

  Monitor installation, last-seen replay, notification, and membership
  broadcasts live with the roster write so every writer has identical lifecycle
  behavior while M-2 remains additive.
  """

  alias Ezagent.ActionSet.Session.{Delivery, Members}

  @anon_user_name_prefix "anon-"

  @spec on_add(URI.t(), pid(), map(), map(), module()) :: {map(), [term()]}
  def on_add(%URI{} = member_uri, member_pid, facets, ctx, source_module)
      when is_pid(member_pid) and is_map(facets) do
    session_uri = ctx[:self_uri]
    members = ctx[:read].(:members, %{})
    monitors = (ctx[:transients] || %{})[:monitors] || %{}
    last_seen = ctx[:read].(:last_seen, %{})
    prior_owner = ctx[:read].(:owner_uri, nil)

    {old_refs_for_member, monitors_without_member} =
      Enum.split_with(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    Enum.each(old_refs_for_member, fn {ref, _uri} ->
      _ = Process.demonitor(ref, [:flush])
    end)

    ref = Process.monitor(member_pid)
    existing_meta = Map.get(members, member_uri, %{})

    new_members =
      Map.put(
        members,
        member_uri,
        Members.put_member_facets(Map.put(existing_meta, :online, true), facets)
      )

    new_monitors =
      monitors_without_member
      |> Map.new()
      |> Map.put(ref, member_uri)

    Delivery.replay_messages_since(session_uri, member_uri, last_seen)
    new_last_seen = Map.delete(last_seen, member_uri)

    claims_owner? = is_nil(prior_owner) and user_uri?(member_uri) and not anon_member?(member_uri)
    new_owner_uri = if claims_owner?, do: member_uri, else: prior_owner

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
        {:set, :owner_uri, new_owner_uri}
      ] ++ Delivery.broadcast_membership_effects(session_uri, {:member_joined, member_uri})

    {new_members, effects}
  end

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false

  defp anon_member?(%URI{scheme: "entity"} = uri) do
    user_uri?(uri) and
      case uri |> URI.to_string() |> String.split("/") |> List.last() do
        nil -> false
        name -> String.starts_with?(name, @anon_user_name_prefix)
      end
  end

  defp anon_member?(_), do: false
end
