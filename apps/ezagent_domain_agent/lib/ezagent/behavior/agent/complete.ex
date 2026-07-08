defmodule Ezagent.ActionSet.Agent.Complete do
  @moduledoc """
  Capability-only Behavior: declares the `:complete` action on the `:agent`
  axis so callers can be granted a `complete` cap for a specific agent URI.

  The `handle_complete/2` handler is a no-op — actual completion goes through
  `Ezagent.Entity.Agent.complete/3` (a direct function call, NOT dispatched).
  This module exists SOLELY to register the `:complete` cap subject so the
  `complete/3` gate can check `holds_cap?(Agent, caller, needed)`.
  """

  use Ezagent.Lifecycle

  action(:complete,
    args: %{prompt: :string},
    returns: %{content: :string},
    caps: [:complete],
    modes: [:call],
    description: "Invoke a synchronous LLM completion from a curl-flavor agent"
  )

  @impl Ezagent.Lifecycle
  @doc false
  def create(_args), do: {:ok, %{}}

  @doc false
  def handle_complete(_args, _ctx), do: {:ok, %{}, []}

  # caps-data-ownership — cap-only Behavior; no per-entity data.
  @doc false
  def data_owner(:any), do: :any

  @doc false
  def data_owner(_), do: :no_owner
end
