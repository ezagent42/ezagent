defmodule Ezagent.KindSupervisor do
  @moduledoc """
  Default DynamicSupervisor for Kind processes whose Kind module does
  not declare its own via the `supervisor/0` callback.

  Per Phase 9 follow-up architectural prevention (V1 prevention
  layers 1+2+4+5, Allen 2026-05-21): `Ezagent.Kind.spawn/2` is the
  SOLE programmatic entry for spawning Kinds. Each Kind may opt to
  use its own DynamicSupervisor (e.g., for per-Kind restart policies
  or domain-app ownership boundaries) via the `supervisor/0` callback;
  those that don't fall back to this default.

  Started as a child in `EzagentActor.Application` so it is always
  available before any plugin or domain app tries to spawn.

  See `Ezagent.Kind.spawn/2` moduledoc + invariant tests
  `apps/ezagent_core/test/invariants/single_spawn_entry_test.exs` and
  `apps/ezagent_core/test/invariants/kind_provenance_test.exs`.
  """
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
