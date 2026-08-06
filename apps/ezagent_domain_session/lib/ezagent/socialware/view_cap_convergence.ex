defmodule Ezagent.Socialware.ViewCapConvergence do
  @moduledoc false

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.Session

  @spec converge(URI.t(), keyword()) :: :ok | {:error, term()}
  def converge(%URI{scheme: "session"} = session_uri, opts \\ []) do
    roster_reader =
      Keyword.get(opts, :roster_reader, &Session.session_member_uris_strict/1)

    grant_member =
      Keyword.get(opts, :grant_member, &Membership.grant_member_view_caps_strict/2)

    case roster_reader.(session_uri) do
      {:ok, members} when is_list(members) ->
        members
        |> Enum.filter(&eligible?/1)
        |> Enum.reduce_while(:ok, fn member_uri, :ok ->
          case grant_member.(session_uri, member_uri) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, {:member_roster_read_failed, session_uri, reason}}

      other ->
        {:error, {:member_roster_read_failed, session_uri, {:unexpected_result, other}}}
    end
  end

  defp eligible?(%URI{} = member_uri) do
    Membership.user_uri?(member_uri) and Ezagent.Users.confirmed?(member_uri)
  end

  defp eligible?(_member_uri), do: false
end
