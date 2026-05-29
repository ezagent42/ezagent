defmodule Ezagent.TestSupport.LifecycleFixture do
  @moduledoc """
  Trivial `use Ezagent.Lifecycle` fixture proving the Phase A macro emits
  a working `@behaviour Ezagent.Behavior` under the two-container model.

  SPEC: `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`
  Phase A acceptance gate — "the macro can emit a working Behavior for a
  trivial fixture (create→state, activate→transients, a handle action
  returning {:set,...}+{:set_transient,...}, cold-restart rebuilds
  transients)."

  ## What it exercises

  - `create/1` builds the PERSISTENT `state` (`counter`, `label`).
  - `activate/2` rebuilds a TRANSIENT — here a live `Agent` pid acting as
    a stand-in for the real-world transient resource class (subprocess /
    ETS handle / monitor ref). On a cold-load the prior incarnation's pid
    is gone; `activate` spawns a fresh one. The pid is stored ONLY in
    `transients`, so it has no serialization path and cannot leak into a
    snapshot.
  - `handle_bump/2` mutates BOTH containers in one return:
    `{:set, :counter, _}` (persistent) + `{:set_transient, :hits, _}`
    (volatile) — the §10-R2 atomic pre-commit reduction.
  """

  use Ezagent.Lifecycle

  action :bump,
    args: %{by: :integer},
    returns: %{counter: :integer},
    caps: [:bump],
    modes: [:call],
    description: "increment the persistent counter + record a transient hit"

  # This fixture is workspace-agnostic (system-scoped URI) — opt out of
  # the dispatch workspace-isolation check so the cold-restart test can
  # dispatch :bump without plumbing a workspace cap.
  @impl Ezagent.Behavior
  def workspace_scoped?, do: false

  # The :bump action is cap-exempt for the fixture (Phase A foundation
  # is not exercising CapBAC — the migration of real caps is Phase B).
  @impl Ezagent.Behavior
  def cap_exempt_actions, do: [:bump]

  # ---- Lifecycle developer hooks ----

  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       counter: Map.get(args, :counter, 0),
       label: Map.get(args, :label, "fixture")
     }}
  end

  @impl Ezagent.Lifecycle
  def activate(state, _ctx) do
    # Rebuild the transient resource from scratch on EVERY start. A live
    # Agent pid stands in for the real transient class. On cold-load the
    # prior pid is dead; this spawns a fresh one seeded from the durable
    # `state.counter`.
    {:ok, agent} = Agent.start_link(fn -> %{seeded_from: state.counter, hits: 0} end)
    {:ok, %{worker: agent, hits: 0}}
  end

  def handle_bump(%{by: by}, ctx) do
    counter = ctx.read.(:counter, 0)
    hits = ctx.transients[:hits] || 0
    new_counter = counter + by

    {:ok, %{counter: new_counter},
     [
       {:set, :counter, new_counter},
       {:set_transient, :hits, hits + 1}
     ]}
  end
end

defmodule Ezagent.TestSupport.LifecycleFixtureKind do
  @moduledoc """
  Kind hosting the single `Ezagent.TestSupport.LifecycleFixture` Lifecycle
  module. `{:snapshot, :on_change}` so the persistent `state` survives a
  cold restart (and the transient is proven to be rebuilt, not restored).
  """
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_fixture

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.LifecycleFixture]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.LifecycleFixtureOverride do
  @moduledoc """
  Second fixture exercising the `state_slice:` override escape hatch
  (SPEC §5 — snapshot-compat). Carries the sanctioned marker comment.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :legacy_compat_key

  action :noop, args: %{}, returns: %{}, caps: [:noop], modes: [:call], description: "no-op"

  @impl Ezagent.Behavior
  def cap_exempt_actions, do: [:noop]

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{ok: true}}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}
end
