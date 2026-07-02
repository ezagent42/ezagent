defmodule Ezagent.Kind.MountDetach do
  @moduledoc """
  RF-2/RF-3 — runtime per-instance behavior MOUNT + DETACH on a LIVE Kind.

  These orchestrate adding/removing a single Behavior to/from a running
  instance's set, mutating the persisted `:kind_base` capture so the change
  survives cold restart (rehydrated by `BehaviorSet.effective_set/2`). The two
  `Ezagent.Kind.Server` `handle_call`s (`:ezagent_mount` / `:ezagent_detach`)
  are thin delegations to the pure-in-process functions here; kept in their own
  module so `server.ex` stays under the `oversized_modules_gt_1000` arch gate.

  ## Why mount runs create + activate + activated (codex HIGH-A)

  A spawn-time slice goes through THREE engine moments: `init_slice`/`create`
  (persistent state), the post-init `handle_continue/3` continuation
  (→ `activate/2`, transients), and `on_ready/2` (→ `activated/2`, post-`:ready`
  reachability broadcasts — e.g. Publisher). Running `init_slice` ALONE
  half-initializes the behavior: its transients are never built live and any
  `activated`-time broadcast never fires. `mount/5` replays ALL THREE for the
  ONE mounted behavior — never for the existing behaviors (re-firing their
  `activate`/`activated` would double-init / re-broadcast).

  ## Re-entrancy bound (spec-accepted)

  mount's post-init/`activated` (and detach's `on_detach`) run INSIDE the
  synchronous `:ezagent_mount`/`:ezagent_detach` `handle_call`, in this Kind's
  own process. They are run best-effort (`try/rescue`) and must stay
  fire-and-forget. A mounted behavior whose `activated`/`on_ready` issues a
  synchronous cross-Kind `:call` that re-enters THIS Kind (the Publisher →
  ExternalMirrorWorker `subscribe`-back pattern) would DEADLOCK until the call
  times out — and `try/rescue` does NOT catch a deadlock. This is the same
  bound the spawn path manages with the ReadyGate sequencing; at runtime-mount
  time the instance is already `:ready`, so a peer `:call` back is structurally
  possible. Deferred/saga to OTHER Kinds is out of scope (per the RF-3 spec).
  Do NOT runtime-mount a Publisher-class behavior whose `activated` invites a
  re-entrant `:call` without first moving that work behind a `handle_signal`
  self-defer.

  ## Transactional safety (live GenServer — cannot `{:stop, …}`)

  Spawn aborts a bad set via `{:stop, …}`. mount/detach run inside a live
  `handle_call` and MUST NOT crash the Kind. Both VALIDATE before mutating:
  mount checks the behavior is a real Behavior and the prospective set is
  closure-clean; detach checks reverse-closure (no remaining behavior still
  `@required_reads` the one being removed). On reject they return
  `{:error, reason}` with ZERO residue (no slice write, no `:kind_base`
  rewrite, no hook run). The mutating side-effects (slice materialization,
  `:kind_base` rewrite, post-init/activated hooks, snapshot) happen ONLY after
  validation passes.
  """

  require Logger

  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Kind.BehaviorSet

  @doc """
  Mount `behavior` onto the LIVE instance whose current slice state is
  `slice_state`. Returns `{:ok, new_slice_state}` with the behavior's slice
  materialized (create + activate + activated run) and `:kind_base` rewritten
  to include it, or `{:error, reason}` with `slice_state` unchanged.

  Idempotent: mounting a behavior already in the effective set is a no-op
  (`{:ok, slice_state}`).

  `args` is merged with `%{uri: uri}` (uri authoritative) and passed to the
  behavior's fresh-slice builder + `activate`, mirroring the spawn contract
  where `init_slice`/`activate` receive the same args map.
  """
  @spec mount(%{atom() => map()}, module(), module(), map(), URI.t()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def mount(slice_state, kind_module, behavior, args, %URI{} = uri)
      when is_map(slice_state) and is_atom(kind_module) and is_atom(behavior) and is_map(args) do
    cond do
      # Already a member → no-op (idempotent). Compute the effective set
      # defensively (a Kind requiring an explicit set with a nil capture would
      # raise — treat that as "not a member" and let the validation below run).
      member_of_effective_set?(kind_module, behavior, slice_state) ->
        {:ok, slice_state}

      not real_behavior?(behavior) ->
        {:error, {:not_a_behavior, behavior}}

      true ->
        do_mount(slice_state, kind_module, behavior, Map.put(args, :uri, uri), uri)
    end
  end

  @doc """
  Detach `behavior` from the LIVE instance. Returns `{:ok, new_slice_state}`
  with the behavior's `on_detach/2` teardown run, its slice dropped, and
  `:kind_base` rewritten to exclude it — or `{:error, reason}` unchanged.

  Rejects (reverse-closure) when a REMAINING behavior still REQUIRES the one
  being detached as a sibling read. `KindBase` and universal behaviors
  (`UniversalBehaviors.all/0`) are base behaviors and cannot be detached.
  Detaching a behavior not in the set is a no-op (`{:ok, slice_state}`).
  """
  @spec detach(%{atom() => map()}, module(), module(), URI.t()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def detach(slice_state, kind_module, behavior, %URI{} = uri)
      when is_map(slice_state) and is_atom(kind_module) and is_atom(behavior) do
    cond do
      behavior in BehaviorSet.base_behaviors() ->
        {:error, {:cannot_detach_base_behavior, behavior}}

      not member_of_effective_set?(kind_module, behavior, slice_state) ->
        # Not present → nothing to remove.
        {:ok, slice_state}

      true ->
        do_detach(slice_state, kind_module, behavior, uri)
    end
  end

  # ---------------------------------------------------------------------------
  # mount
  # ---------------------------------------------------------------------------

  defp do_mount(slice_state, kind_module, behavior, args, uri) do
    current = effective_set_safe(kind_module, slice_state)
    prospective = current ++ [behavior]

    # Re-validate closure on the PROSPECTIVE set BEFORE any mutation. A mount
    # that would leave the set unclosed under a REQUIRED sibling read is
    # rejected with zero residue (symmetric with spawn's first-spawn
    # validate_closure!/1, which aborts via {:stop, …}).
    case BehaviorSet.resolve_closure(prospective) do
      :ok ->
        materialize_and_attach(slice_state, kind_module, behavior, args, uri, prospective)

      {:error, reason} ->
        {:error, {:unclosed_set, reason}}
    end
  end

  defp materialize_and_attach(slice_state, kind_module, behavior, args, uri, prospective) do
    # 1. Build the behavior's FRESH slice (create — never the marker SKIP) and
    #    add the :kind_base capture FIRST so effective_set/materialized_set
    #    include the new behavior for the hook runs below.
    slice_key = behavior.state_slice()
    fresh_slice = fresh_slice_for(behavior, args)

    new_slice_state =
      slice_state
      |> Map.put(slice_key, fresh_slice)
      |> rewrite_kind_base(prospective)

    ctx = %{kind_module: kind_module, self_uri: uri}

    # 2. post-init continuation (→ activate/2: build transients) for ONLY the
    #    mounted behavior — never the existing ones.
    new_slice_state = run_single_post_init(behavior, args, new_slice_state, ctx)

    # 3. on_ready (→ activated/2: post-`:ready` reachability broadcast) for
    #    ONLY the mounted behavior. The instance is already `:ready`, so this
    #    is the correct moment (best-effort; isolated).
    run_single_on_ready(behavior, new_slice_state, ctx)

    {:ok, new_slice_state}
  end

  # Lifecycle behaviors gate create on the ever-created marker (TRUE by mount
  # time) → use the unconditional-fresh mount builder so create runs. A
  # non-Lifecycle behavior has no marker gate → init_slice/1 is the fresh
  # builder.
  defp fresh_slice_for(behavior, args) do
    if lifecycle_behavior?(behavior) do
      Ezagent.Lifecycle.__mount_slice__(behavior, args)
    else
      behavior.init_slice(args)
    end
  end

  # Single-behavior analogue of Kind.Server.collect_post_init_queue/3 +
  # the handle_continue/3 continuation: call post_init/2; if it returns
  # {:continue, term}, run handle_continue/3 and merge the new slice back.
  defp run_single_post_init(behavior, args, slice_state, ctx) do
    slice_key = behavior.state_slice()
    slice = Map.get(slice_state, slice_key, %{})

    if function_exported?(behavior, :post_init, 2) do
      case behavior.post_init(args, slice) do
        :ok ->
          slice_state

        {:continue, term} ->
          run_continuation(behavior, term, slice_state, ctx)
      end
    else
      slice_state
    end
  end

  defp run_continuation(behavior, term, slice_state, ctx) do
    slice_key = behavior.state_slice()
    slice = Map.get(slice_state, slice_key, %{})

    if function_exported?(behavior, :handle_continue, 3) do
      case behavior.handle_continue(term, slice, ctx) do
        {:ok, new_slice} -> Map.put(slice_state, slice_key, new_slice)
        :ignore -> slice_state
      end
    else
      Logger.warning(
        "Ezagent.Kind.MountDetach: behavior #{inspect(behavior)} returned " <>
          "{:continue, #{inspect(term)}} from post_init/2 but does not export " <>
          "handle_continue/3; dropping continuation. URI=#{URI.to_string(ctx.self_uri)}"
      )

      slice_state
    end
  end

  defp run_single_on_ready(behavior, slice_state, ctx) do
    run_on_ready(behavior, Map.get(slice_state, behavior.state_slice(), %{}), ctx)
  end

  @doc """
  Run each INSTANCE-effective behavior's optional `on_ready/2` AFTER the
  ReadyGate has flipped to `:ready` and the PendingDelivery buffer has drained
  (the post-`:ready` reachability-broadcast hook — e.g. Publisher).

  Extracted from `Ezagent.Kind.Server` (RF-2; keeps server.ex under the
  `oversized_modules_gt_1000` gate) and shared with `mount/5`'s single-behavior
  path (`run_single_on_ready`) so on_ready execution + per-behavior isolation
  live in ONE place. P1 (SPEC §3.1, E2): only the instance effective set runs.

  Best-effort: a raise/throw/exit inside any one behavior's `on_ready/2` is
  logged + isolated; the Kind stays `:ready` (an external observer may already
  have seen `:ready`); siblings still run.
  """
  @spec run_on_ready_all(module(), URI.t(), %{atom() => map()}) :: :ok
  def run_on_ready_all(kind_module, self_uri, slice_state) do
    ctx = %{kind_module: kind_module, self_uri: self_uri}

    Enum.each(BehaviorSet.materialized_set(kind_module, slice_state), fn behavior ->
      run_on_ready(behavior, Map.get(slice_state, behavior.state_slice(), %{}), ctx)
    end)
  end

  # Single-behavior on_ready runner. Best-effort, isolated — a raise/throw/exit
  # is logged + swallowed so a buggy on_ready never strands the mount / blocks
  # siblings.
  defp run_on_ready(behavior, slice, ctx) do
    if function_exported?(behavior, :on_ready, 2) do
      try do
        _ = behavior.on_ready(slice, ctx)
      rescue
        err ->
          Logger.warning(
            "Ezagent.Kind.MountDetach: #{inspect(behavior)}.on_ready/2 raised " <>
              "(#{inspect(err)}). Kind remains `:ready`; continuing. " <>
              "URI=#{URI.to_string(ctx.self_uri)}"
          )
      catch
        kind, value ->
          Logger.warning(
            "Ezagent.Kind.MountDetach: #{inspect(behavior)}.on_ready/2 threw " <>
              "#{inspect({kind, value})}. Kind remains `:ready`; continuing. " <>
              "URI=#{URI.to_string(ctx.self_uri)}"
          )
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # detach
  # ---------------------------------------------------------------------------

  defp do_detach(slice_state, kind_module, behavior, uri) do
    remaining = effective_set_safe(kind_module, slice_state) -- [behavior]

    # REVERSE-CLOSURE: reject if a REMAINING behavior still requires the
    # detaching behavior as a sibling-read owner. resolve_closure on the
    # remaining set surfaces exactly that — a missing required owner that is
    # the behavior we are about to remove.
    case reverse_closure_block(remaining, behavior) do
      :ok ->
        teardown_and_remove(slice_state, kind_module, behavior, uri, remaining)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reverse_closure_block(remaining, behavior) do
    case BehaviorSet.resolve_closure(remaining) do
      :ok ->
        :ok

      {:error, {:missing_required_siblings, missing}} ->
        # Is the now-missing required owner the behavior being detached? If so,
        # the detach is what broke closure → reject. (A pre-existing unclosed
        # set unrelated to `behavior` is not introduced by this detach, but we
        # still reject any closure break to keep the live set always-closed.)
        {:error, {:still_required, behavior, missing}}

      {:error, other} ->
        {:error, other}
    end
  end

  defp teardown_and_remove(slice_state, kind_module, behavior, uri, remaining) do
    ctx = %{kind_module: kind_module, self_uri: uri}

    # 1. Run the per-behavior teardown hook (side-effecting cleanup of
    #    transient handles) BEFORE dropping the slice — best-effort, isolated.
    run_on_detach(behavior, slice_state, ctx)

    # 2. Drop the behavior's slice + rewrite :kind_base to exclude it.
    slice_key = behavior.state_slice()

    new_slice_state =
      slice_state
      |> Map.delete(slice_key)
      |> rewrite_kind_base(remaining)

    {:ok, new_slice_state}
  end

  defp run_on_detach(behavior, slice_state, ctx) do
    if function_exported?(behavior, :on_detach, 2) do
      slice = Map.get(slice_state, behavior.state_slice(), %{})

      try do
        _ = behavior.on_detach(slice, ctx)
      rescue
        err ->
          Logger.warning(
            "Ezagent.Kind.MountDetach: #{inspect(behavior)}.on_detach/2 raised " <>
              "(#{inspect(err)}); detach proceeds. URI=#{URI.to_string(ctx.self_uri)}"
          )
      catch
        kind, value ->
          Logger.warning(
            "Ezagent.Kind.MountDetach: #{inspect(behavior)}.on_detach/2 threw " <>
              "#{inspect({kind, value})}; detach proceeds. URI=#{URI.to_string(ctx.self_uri)}"
          )
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # shared
  # ---------------------------------------------------------------------------

  # Rewrite the :kind_base capture to the PRESENT-LIST form of `set` MINUS the
  # base behaviors (KindBase + universal). The capture mirrors what spawn would
  # have persisted for `%{behaviors: <non-base set>}`: base behaviors are
  # re-appended by effective_set/2's `++ base_behaviors()`, so storing them in
  # the capture would be redundant. We store the NON-base members as an
  # explicit present list (never the legacy nil sentinel) so reload rehydrates
  # the exact set.
  defp rewrite_kind_base(slice_state, set) do
    base = MapSet.new(BehaviorSet.base_behaviors())
    captured = Enum.reject(set, &MapSet.member?(base, &1))
    kind_base_key = KindBase.state_slice()

    Map.update(
      slice_state,
      kind_base_key,
      KindBase.put_behaviors(%{state: %{behaviors: captured}, transients: %{}}, captured),
      fn existing -> KindBase.put_behaviors(existing, captured) end
    )
  end

  defp effective_set_safe(kind_module, slice_state) do
    BehaviorSet.effective_set(kind_module, slice_state)
  rescue
    Ezagent.Kind.BehaviorSet.MissingKindBaseError -> BehaviorSet.base_behaviors()
  end

  defp member_of_effective_set?(kind_module, behavior, slice_state) do
    behavior in effective_set_safe(kind_module, slice_state)
  end

  defp real_behavior?(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    Code.ensure_loaded?(mod) and Ezagent.ActionSet.new_style?(mod)
  end

  defp real_behavior?(_), do: false

  defp lifecycle_behavior?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__ezagent_lifecycle_destroy__, 3)
  end
end
