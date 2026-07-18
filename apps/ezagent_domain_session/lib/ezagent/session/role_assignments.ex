defmodule Ezagent.Session.RoleAssignments do
  @moduledoc """
  Operator-facing entry for assigning open socialware human roles.

  The facade dispatches the isomorphic `session.assign_role` action, keeping the
  member metadata mutation inside the Session behavior chokepoint.
  """

  alias Ezagent.Invocation

  @type ctx :: %{required(:caller) => URI.t(), optional(:caps) => Enumerable.t()}

  @doc """
  Assign a session-installed human role slot to an existing user member.

  This delegates through `session.assign_role` so authorization and member-edge
  writes stay behind the Session behavior.
  """
  @spec assign_role(URI.t(), URI.t(), String.t(), ctx()) ::
          {:ok, %{member: URI.t(), role_name: String.t()}} | {:error, term()}
  def assign_role(
        %URI{} = session_uri,
        %URI{} = member_uri,
        role_name,
        %{caller: %URI{} = caller} = ctx
      )
      when is_binary(role_name) do
    with :ok <- require_user_member(member_uri) do
      result =
        Invocation.dispatch(%Invocation{
          target: Ezagent.URI.with_action(session_uri, :session, :assign_role),
          mode: :call,
          args: %{member: member_uri, role_name: role_name},
          ctx: %{
            caller: caller,
            caps: ctx |> Map.get(:caps, []) |> to_cap_set(),
            reply: {:caller_inbox, self()}
          },
          origin: :trusted_internal
        })

      case result do
        {:ok, %{member: %URI{}, role_name: role_name} = assigned} when is_binary(role_name) ->
          {:ok, assigned}

        {:error, _reason} = err ->
          err

        other ->
          {:error, {:unexpected_assign_role_result, other}}
      end
    end
  end

  def assign_role(_session_uri, %URI{} = member_uri, _role_name, _ctx) do
    require_user_member(member_uri)
  end

  defp require_user_member(uri) do
    case user_member_uri?(uri) do
      true -> :ok
      false -> {:error, :assign_role_requires_user_uri}
    end
  end

  defp user_member_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_member_uri?(_), do: false

  defp to_cap_set(%MapSet{} = caps), do: caps
  defp to_cap_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp to_cap_set(_), do: MapSet.new()
end
