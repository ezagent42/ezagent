defmodule Ezagent.Test.TestBehavior do
  @moduledoc """
  Minimal Behavior used by Kind.Server / Invocation / Runtime tests.
  Lives under `test/support/` (compiled only in `:test` per
  `mix.exs` `elixirc_paths(:test)`).

  Action `:noop` updates the slice's `:count` field; action `:fail`
  returns `{:error, :test_failure}`.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop, :fail, :raise]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:noop, "test — no-op action"},
      {:fail, "test — returns {:error, _}"},
      {:raise, "test — raises an exception"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :test

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{count: 0, last_msg: nil}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, %{msg: msg}, _ctx) do
    {:ok, %{slice | count: slice.count + 1, last_msg: msg}, %{echoed: msg}}
  end

  def invoke(:fail, _slice, _args, _ctx), do: {:error, :test_failure}

  def invoke(:raise, _slice, _args, _ctx), do: raise("boom")

  @impl Ezagent.Behavior
  def interface do
    %{
      noop: %{
        description: "Bump the slice counter and echo the message",
        args: %{msg: :string},
        returns: %{echoed: :string},
        modes: [:call, :cast]
      },
      fail: %{
        description: "Always return {:error, :test_failure}",
        args: %{},
        returns: %{},
        modes: [:call]
      },
      raise: %{
        description: "Always raise — exercises the crash path",
        args: %{},
        returns: %{},
        modes: [:call]
      }
    }
  end
end

defmodule Ezagent.Test.TestKind do
  @moduledoc "Minimal Kind that uses `Ezagent.Test.TestBehavior`."

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Test.TestBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end
