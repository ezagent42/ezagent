defmodule Ezagent.Socialware.TestCapHelper do
  @moduledoc false

  @downstream_actions [
    {:session, :send},
    {:surface, :put_version},
    {:surface, :approve},
    {:surface, :commit_settlement}
  ]

  def lifecycle_caps(%URI{} = session, %URI{} = caller, %URI{} = primary_target) do
    targets =
      [primary_target | Enum.map(@downstream_actions, &action_target(session, &1))]
      |> Enum.uniq_by(&URI.to_string/1)

    targets
    |> Enum.map(&Ezagent.Test.CapHelper.signed_action_cap!(&1, caller))
    |> MapSet.new()
  end

  defp action_target(session, {behavior, action}) do
    Ezagent.URI.with_action(session, behavior, action)
  end
end
