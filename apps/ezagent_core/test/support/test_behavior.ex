defmodule Ezagent.Test.TestBehavior do
  @moduledoc """
  Minimal Behavior used by Kind.Server / Invocation / Runtime tests.
  Lives under `test/support/` (compiled only in `:test` per
  `mix.exs` `elixirc_paths(:test)`).

  Migrated to the new per-action declarative contract (`use
  Ezagent.ActionSet`) as part of Phase 3 r3 (2026-05-28); the legacy
  `invoke/4` dispatch path is gone, so every Behavior the Runtime
  sees MUST be new-style.

  Action `:noop` updates the slice's `:count` field; action `:fail`
  returns `{:error, :test_failure}`; action `:raise` raises.
  """

  use Ezagent.ActionSet
  @behaviour Ezagent.ActionSet

  action(:noop,
    args: %{msg: :string},
    returns: %{echoed: :string},
    modes: [:call, :cast],
    description: "Bump the slice counter and echo the message"
  )

  action(:fail,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "Always return {:error, :test_failure}"
  )

  action(:raise,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "Always raise — exercises the crash path"
  )

  @impl Ezagent.ActionSet
  def state_slice, do: :test

  @impl Ezagent.ActionSet
  def init_slice(_args), do: %{count: 0, last_msg: nil}

  def handle_noop(%{msg: msg}, ctx) do
    count = ctx[:read].(:count, 0)

    {:ok, %{echoed: msg},
     [
       {:set, :count, count + 1},
       {:set, :last_msg, msg}
     ]}
  end

  def handle_fail(_args, _ctx), do: {:error, :test_failure}

  def handle_raise(_args, _ctx), do: raise("boom")
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

defmodule Ezagent.Test.OnChangeTestKind do
  @moduledoc """
  Allen 2026-05-25 — minimal `{:snapshot, :on_change}` Kind used by the
  CLI-persistence invariant test
  (`kind_init_persists_initial_snapshot_test.exs`).
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Test.TestBehavior]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.Test.OnTerminateTestKind do
  @moduledoc """
  Allen 2026-05-25 — minimal `:on_terminate` Kind used by the
  CLI-persistence invariant test. `:on_terminate` is the policy
  `Ezagent.Entity.Agent` uses, and the one the CLI bug
  (`mix ezagent.agent.create` → BEAM exit before terminate completes
  in some races) primarily affects.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Test.TestBehavior]

  @impl Ezagent.Kind
  def persistence, do: :on_terminate
end
