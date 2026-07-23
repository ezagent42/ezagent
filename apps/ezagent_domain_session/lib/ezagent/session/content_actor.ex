defmodule Ezagent.Session.ContentActor do
  @moduledoc false

  @doc false
  @spec authorize(map()) :: :ok | {:error, term()}
  def authorize(ctx) when is_map(ctx) do
    holder = Map.get(ctx, :authenticated_principal)
    session_uri = Map.get(ctx, :self_uri)

    if same_uri?(holder, session_uri) do
      :ok
    else
      Ezagent.Session.Membership.authorize(%{}, holder, session_uri, holder)
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end

  defp same_uri?(_, _), do: false
end
