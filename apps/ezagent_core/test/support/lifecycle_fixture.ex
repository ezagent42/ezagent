defmodule Ezagent.TestSupport.LifecycleFixture do
  @moduledoc """
  Trivial `use Ezagent.Lifecycle` fixture proving the Phase A macro emits
  a working `@behaviour Ezagent.ActionSet` under the two-container model.

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

  action(:bump,
    args: %{by: :integer},
    returns: %{counter: :integer},
    caps: [:bump],
    modes: [:call],
    description: "increment the persistent counter + record a transient hit"
  )

  # This fixture is workspace-agnostic (system-scoped URI) — opt out of
  # the dispatch workspace-isolation check so the cold-restart test can
  # dispatch :bump without plumbing a workspace cap.
  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false

  # The :bump action is cap-exempt for the fixture (Phase A foundation
  # is not exercising CapBAC — the migration of real caps is Phase B).
  @impl Ezagent.ActionSet
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

  # P6 cold-restart determinism: host THE GATE Kind on the dedicated
  # gate supervisor, isolating its kill→restart cycle from the shared
  # `Ezagent.KindSupervisor`'s restart-intensity exhaustion. See
  # `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`.
  @impl Ezagent.Kind
  def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
end

defmodule Ezagent.TestSupport.LifecycleFixtureOverride do
  @moduledoc """
  Second fixture exercising the `state_slice:` override escape hatch
  (SPEC §5 — snapshot-compat). Carries the sanctioned marker comment.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :legacy_compat_key

  action(:noop, args: %{}, returns: %{}, caps: [:noop], modes: [:call], description: "no-op")

  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:noop]

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{ok: true}}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}
end

defmodule Ezagent.TestSupport.TransientOnlyFixture do
  @moduledoc """
  Lifecycle fixture whose `:tick` action mutates ONLY a transient
  (`{:set_transient, :hits, _}`). Used to prove a transient-only change
  does NOT fire a SliceChange (F1a). `state_slice` is pinned so the test
  can read it by a stable key.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :transient_only

  action(:tick, args: %{}, returns: %{}, caps: [:tick], modes: [:call], description: "tick")

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:tick]

  @impl Ezagent.Lifecycle
  def create(_), do: {:ok, %{counter: 0}}
  @impl Ezagent.Lifecycle
  def activate(_s, _c), do: {:ok, %{hits: 0}}

  def handle_tick(_args, ctx) do
    {:ok, %{}, [{:set_transient, :hits, (ctx.transients[:hits] || 0) + 1}]}
  end
end

defmodule Ezagent.TestSupport.TransientOnlyKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_transient_only
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.TransientOnlyFixture]
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.LifecycleDestroyFixture do
  @moduledoc """
  Lifecycle fixture exercising `destroy/2` (F4) + `deactivate/2` (F5).
  Both record their invocation into a test-supplied ETS table so the
  test can assert the developer hook actually ran (with access to its
  `state`) before the framework cleared durable state.
  """

  use Ezagent.Lifecycle

  action(:touch,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:touch],
    modes: [:call],
    description: "touch"
  )

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:touch]

  @impl Ezagent.Lifecycle
  def create(args), do: {:ok, %{label: Map.get(args, :label, "d"), probe: Map.get(args, :probe)}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @impl Ezagent.Lifecycle
  def destroy(reason, ctx) do
    # Record that destroy ran, WITH access to the still-live state. The
    # probe is an ETS table id (a reference).
    case ctx.state[:probe] do
      nil -> :ok
      probe -> :ets.insert(probe, {:destroyed, reason, ctx.read.(:label, nil)})
    end

    :ok
  end

  @impl Ezagent.Lifecycle
  def deactivate(reason, ctx) do
    # F5: deactivate is :ok-only — it CANNOT mutate persisted state. We
    # record the call (a side effect) but return :ok; any state we tried
    # to return would be discarded by __run_deactivate__.
    case ctx.state[:probe] do
      nil -> :ok
      probe -> :ets.insert(probe, {:deactivated, reason})
    end

    :ok
  end

  def handle_touch(_args, _ctx), do: {:ok, %{ok: true}, []}
end

defmodule Ezagent.TestSupport.LifecycleDestroyKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_destroy_fixture
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.LifecycleDestroyFixture]
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.SelfDestroyFixture do
  @moduledoc """
  Lifecycle fixture whose `:boom` handler calls
  `Ezagent.Lifecycle.destroy(ctx.self_uri)` — i.e. it tries to destroy
  the very Kind it is running inside (codex r2 F2). The handler runs IN
  the Kind.Server process, so the inner destroy's hook-drain
  `GenServer.call(self(), …)` would re-enter this GenServer. The fix
  REJECTS the self-call with `{:error, :cannot_self_destroy}` BEFORE the
  durable row is cleared / the process is terminated, so the test can
  assert NEITHER the torn "row gone but alive" state NOR an honest
  destruction occurs — the entity is left fully intact.

  The handler records the rejection result into a test-supplied ETS probe
  so the test can confirm the handler observed `{:error,
  :cannot_self_destroy}` (not `:ok`, not a deadlock).
  """

  use Ezagent.Lifecycle

  action(:boom,
    args: %{},
    returns: %{result: :term},
    caps: [:boom],
    modes: [:call],
    description: "attempt to self-destroy from inside the handler (F2 footgun)"
  )

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:boom]

  @impl Ezagent.Lifecycle
  def create(args),
    do: {:ok, %{label: Map.get(args, :label, "self"), probe: Map.get(args, :probe)}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  def handle_boom(_args, ctx) do
    # Self-destroy: target == ctx.self_uri == THIS Kind. Must be rejected
    # structurally, NOT half-completed.
    result = Ezagent.Lifecycle.destroy(ctx.self_uri, :self_requested)

    case ctx.read.(:probe, nil) do
      nil -> :ok
      probe -> :ets.insert(probe, {:boom_result, result})
    end

    {:ok, %{result: result}, []}
  end
end

defmodule Ezagent.TestSupport.SelfDestroyKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_self_destroy_fixture
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.SelfDestroyFixture]
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.LifecycleInterceptFixture do
  @moduledoc """
  Lifecycle fixture exercising the FINE interception hooks
  `pre_handle/3` + `post_handle/4` (F6). `pre_handle` may rewrite args
  or halt; `post_handle` may inject an effect / rewrite the result.
  """

  use Ezagent.Lifecycle

  action(:run,
    args: %{n: :integer},
    returns: %{n: :integer},
    caps: [:run],
    modes: [:call],
    description: "run"
  )

  action(:guarded,
    args: %{},
    returns: %{},
    caps: [:guarded],
    modes: [:call],
    description: "guarded"
  )

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:run, :guarded]

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{seen: nil, post_marker: nil}}
  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  # pre_handle rewrites :run's args (doubles n) and HALTS :guarded.
  @impl Ezagent.Lifecycle
  def pre_handle(:run, %{n: n} = args, _ctx), do: {:cont, %{args | n: n * 2}}
  def pre_handle(:guarded, _args, _ctx), do: {:halt, %{denied: true}}

  # post_handle for :run injects a {:set, :post_marker, _} effect AND
  # rewrites the result to flag that it ran. Returns the SPEC §2
  # `{:ok, result, effects}` shape.
  @impl Ezagent.Lifecycle
  def post_handle(:run, result, effects, _ctx) do
    {:ok, Map.put(result, :post, true), effects ++ [{:set, :post_marker, :ran}]}
  end

  def post_handle(_action, _result, _effects, _ctx), do: :cont

  def handle_run(%{n: n}, _ctx) do
    {:ok, %{n: n}, [{:set, :seen, n}]}
  end

  def handle_guarded(_args, _ctx) do
    # Should never run — pre_handle halts before reaching here.
    {:ok, %{reached: true}, [{:set, :seen, :should_not_happen}]}
  end
end

defmodule Ezagent.TestSupport.LifecycleInterceptKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_intercept_fixture
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.LifecycleInterceptFixture]
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

# ---------------------------------------------------------------------
# F2 — mixed legacy / Lifecycle sibling-read coexistence fixtures.
#
# A single Kind composes THREE behaviors:
#   - LegacySibling   — old-style flat slice `%{keys: %{...}}` (NOT yet
#     converted).
#   - LifecycleSibling — converted; its slice is the two-container shape
#     `%{state: %{keys: %{...}}, transients: %{}}`.
#   - SiblingReader   — declares `reads_siblings [:legacy_sibling,
#     :lifecycle_sibling]` and, on :read, records BOTH `ctx.sibling_slices`
#     (legacy reader surface) and `ctx.siblings` (Lifecycle reader surface)
#     into its result so the test can assert flat fields resolve for BOTH
#     siblings regardless of their conversion shape.
# ---------------------------------------------------------------------

defmodule Ezagent.TestSupport.LegacySibling do
  @moduledoc false
  use Ezagent.ActionSet

  # Force a stable slice key (snapshot-compat); legacy-flat shape.
  def state_slice, do: :legacy_sibling
  def init_slice(_args), do: %{keys: %{"deepseek" => "legacy-key"}}

  # No actions — it's a pure data sibling, registered for its slice only.
  def actions, do: []
  def required_caps, do: %{}
  def cap_subjects, do: []
  def interface, do: %{}
end

defmodule Ezagent.TestSupport.LifecycleSibling do
  @moduledoc false
  use Ezagent.Lifecycle, state_slice: :lifecycle_sibling

  # lifecycle:state_slice_override
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{keys: %{"deepseek" => "lifecycle-key"}}}
  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{conn: make_ref()}}
end

defmodule Ezagent.TestSupport.SiblingReader do
  @moduledoc false
  use Ezagent.Lifecycle

  reads_siblings([:legacy_sibling, :lifecycle_sibling])

  action(:read,
    args: %{},
    returns: %{},
    caps: [:read],
    modes: [:call],
    description: "read siblings"
  )

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:read]

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}
  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  def handle_read(_args, ctx) do
    # Read via BOTH surfaces, using FLAT field access (what a legacy
    # reader does). If a sibling's two-container shape leaked through,
    # `[:keys]` would be nil → the assertions catch it.
    via_sibling_slices = %{
      legacy: ctx.sibling_slices[:legacy_sibling][:keys]["deepseek"],
      lifecycle: ctx.sibling_slices[:lifecycle_sibling][:keys]["deepseek"]
    }

    via_siblings = %{
      legacy: ctx.siblings[:legacy_sibling][:keys]["deepseek"],
      lifecycle: ctx.siblings[:lifecycle_sibling][:keys]["deepseek"]
    }

    {:ok, %{via_sibling_slices: via_sibling_slices, via_siblings: via_siblings}, []}
  end
end

defmodule Ezagent.TestSupport.SiblingMixKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_sibling_mix

  # Declaration order is intentionally "reader first, then siblings" so
  # the test also proves order-independence of conversion vs read.
  @impl Ezagent.Kind
  def behaviors,
    do: [
      Ezagent.TestSupport.SiblingReader,
      Ezagent.TestSupport.LegacySibling,
      Ezagent.TestSupport.LifecycleSibling
    ]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.LifecycleSignalFixture do
  @moduledoc """
  Lifecycle fixture exercising T1 — a `handle_signal/2` returning the
  FULL effect grammar (not just `:set` / `:set_transient`). A real signal
  handler DISPATCHES / EMITS / NOTIFIES (e.g. ExternalMirror's
  `:publisher_event`/`:ezagent_em_reconcile`, Chat's `:DOWN`); under
  Lifecycle those are declarative effects the signal path MUST execute.

  Two signal messages:

  - `{:lifecycle_signal_notify, topic}` → returns `{:set, :signaled, true}`
    + `{:set_transient, :signal_hits, n+1}` + `{:notify, topic, payload}`.
    Proves a `:notify` side-effect bucket actually broadcasts AND both
    containers advance (R10-2 pre-commit ordering).
  - `{:lifecycle_signal_dispatch, target_uri}` → returns
    `{:dispatch, %Cmd{}}` to `target_uri`'s `:bump` action. Proves a
    cross-Kind `:dispatch` effect from a signal actually re-enters the
    Router (the imperative-Invocation-in-dev-code elimination).
  """

  use Ezagent.Lifecycle, state_slice: :lifecycle_signal

  # lifecycle:state_slice_override
  action(:noop, args: %{}, returns: %{}, caps: [:noop], modes: [:call], description: "noop")

  @impl Ezagent.ActionSet
  def workspace_scoped?, do: false
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:noop]

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{signaled: false, dispatched_to: nil}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{signal_hits: 0}}

  @impl Ezagent.Lifecycle
  def handle_signal({:lifecycle_signal_notify, topic}, ctx) do
    hits = ctx.transients[:signal_hits] || 0

    {:ok,
     [
       {:set, :signaled, true},
       {:set_transient, :signal_hits, hits + 1},
       {:notify, topic, {:lifecycle_signal_fired, ctx.self_uri}}
     ]}
  end

  def handle_signal({:lifecycle_signal_dispatch, %URI{} = target_uri}, ctx) do
    bump_target = URI.new!("#{URI.to_string(target_uri)}?action=lifecycle_fixture.bump")
    cap = :persistent_term.get({__MODULE__, :bump_cap})

    {:ok,
     [
       {:set, :dispatched_to, target_uri},
       {:dispatch,
        %Ezagent.Cmd{
          target: bump_target,
          action: :bump,
          args: %{by: 7},
          ctx: %{
            caller: ctx.self_uri,
            authenticated_principal: ctx.self_uri,
            caps: MapSet.new([cap]),
            reply: :none
          },
          origin: :trusted_internal
        }}
     ]}
  end

  def handle_signal(_other, _ctx), do: :ignore

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}
end

defmodule Ezagent.TestSupport.LifecycleSignalKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :lifecycle_signal_fixture
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.LifecycleSignalFixture]
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end
