defmodule Ezagent.Test.SelfIssueBehavior do
  @moduledoc false

  use Ezagent.ActionSet
  @behaviour Ezagent.ActionSet

  action(:mint_for_self,
    args: %{},
    returns: %{key_id: :string},
    modes: [:call],
    description: "Exercise the target-process self-issue seam"
  )

  action(:noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "Capability shape minted by the self-issue fixture"
  )

  @impl true
  def state_slice, do: :self_issue

  @impl true
  def init_slice(_args), do: %{}

  def handle_mint_for_self(_args, ctx) do
    requested =
      Ezagent.Capability.cap(
        :agent,
        __MODULE__,
        :noop,
        ctx.self_uri,
        Ezagent.Capability.workspace_of(ctx.self_uri)
      )

    case Ezagent.Cap.issue(
           {:admin, Ezagent.URI.user(:system, :admin)},
           ctx.self_uri,
           requested
         ) do
      {:ok, cap} -> {:ok, %{key_id: cap.key_id}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}
end
