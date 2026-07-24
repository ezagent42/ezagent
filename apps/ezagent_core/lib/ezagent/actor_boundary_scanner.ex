defmodule Ezagent.ActorBoundaryScanner do
  @moduledoc """
  Single source of truth for the actor-framework extraction boundary gate
  (spec `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  §4). Both the ExUnit gate
  (`apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs`, PR-gate
  parity) and `mix ezagent.check_invariants` invariant #13 (ci.local parity)
  delegate to this module — §4.5.

  ## Two directions (§4.2)

  - **FORWARD ("The rule")** — non-framework code (`apps/*/lib`, excluding the
    §1/§3.2 mover set) must not reach INTO actor internals (banned ROOTS, the
    `:ezagent_*` GenServer / `Kind.get_slice/get_raw_slice/runtime_view` / process-
    generation shapes, `ReadyGate.<fn>` except `register_external_gate`). Seeds
    the §4.4 census.
  - **REVERSE ("Reverse direction")** — the mover set must not reach UP into the
    staying-core cap/authority/policy spine. Seeds the §3.4 port worklist.

  ## SITE-level ratchet (not file/module level)

  The ledger is a set of SITE fingerprints, each `{path, target, content_sha}` —
  the SHA of the trimmed offending source line. Enforcement = `scanned − ledger`
  must be EMPTY, so a NEW reach-in — even inside an already-allowlisted file, or
  naming an already-allowlisted module — has a new content SHA, is absent from
  the ledger, and REDS the gate. Content-anchoring (not line-anchoring) keeps it
  resistant to unrelated insertions while still catching every new/changed site.
  The ledger can only shrink: a stale entry (no longer scanned) fails the exact
  test, forcing its removal as reach-ins migrate onto the §2.2 read surface.
  """

  @core_lib "apps/ezagent_core/lib"

  # ── The §1/§3.2 mover set (reverse scan target; forward scan exclusion) ─────
  @mover_files ~w(
    ezagent/kind.ex
    ezagent/lifecycle.ex
    ezagent/invocation.ex
    ezagent/router.ex
    ezagent/cmd.ex
    ezagent/kind_registry.ex
    ezagent/ready_gate.ex
    ezagent/pending_delivery.ex
    ezagent/idempotency.ex
    ezagent/idempotency/sweeper.ex
    ezagent/snapshot_store.ex
    ezagent/snapshot/writer.ex
    ezagent/spawn_registry.ex
    ezagent/local_runtime.ex
    ezagent/slice_change.ex
    ezagent/slice_change/cursors.ex
    ezagent/behavior.ex
    ezagent/behavior/effects.ex
    ezagent/behavior/kind_base.ex
    ezagent/behavior/legacy_callbacks.ex
    ezagent/behavior/introspection.ex
    ezagent/behavior_registry.ex
    ezagent/universal_behaviors.ex
    ezagent/interface_validator.ex
    ezagent/uri.ex
    ezagent/uri/scheme_registry.ex
    ezagent/ecto/kind_snapshot.ex
    ezagent/ecto/uri_type.ex
    ezagent/kind/behavior_set.ex
    ezagent/kind/cascade_hook.ex
    ezagent/kind/deferred_dispatch.ex
    ezagent/kind/identity_read_error.ex
    ezagent/kind/introspection.ex
    ezagent/kind/kind_base_backfill.ex
    ezagent/kind/launch_context_init.ex
    ezagent/kind/launch_context_relay.ex
    ezagent/kind/mount_detach.ex
    ezagent/kind/ready_transition.ex
    ezagent/kind/runtime.ex
    ezagent/kind/runtime/context.ex
    ezagent/kind/runtime/effects.ex
    ezagent/kind/runtime/receipt.ex
    ezagent/kind/server.ex
    ezagent/kind/slice_access.ex
    ezagent/kind/snapshot.ex
    ezagent/kind/spawner.ex
    ezagent/kind/state_rebuilder.ex
    ezagent/kind/termination.ex
    ezagent_core/kind_supervisor.ex
  )

  # ── FORWARD config ─────────────────────────────────────────────────────────
  @banned_internal_modules MapSet.new([
                             Ezagent.KindRegistry,
                             Ezagent.PendingDelivery,
                             Ezagent.Idempotency,
                             Ezagent.SnapshotStore,
                             Ezagent.Snapshot.Writer,
                             Ezagent.Ecto.KindSnapshot,
                             Ezagent.Kind.StateRebuilder,
                             Ezagent.Kind.Snapshot,
                             Ezagent.Kind.SliceAccess,
                             Ezagent.Kind.Server,
                             Ezagent.Kind.BehaviorSet,
                             Ezagent.Kind.Spawner,
                             Ezagent.Kind.ReadyTransition,
                             Ezagent.Kind.MountDetach,
                             Ezagent.Kind.Termination,
                             Ezagent.Kind.DeferredDispatch,
                             Ezagent.Kind.CascadeHook,
                             Ezagent.Kind.LaunchContextInit,
                             Ezagent.Kind.LaunchContextRelay
                           ])

  @banned_internal_prefix "Elixir.Ezagent.Kind.Runtime"

  # `Kind.<fn>` reach-ins that go actor-internal (§2.4). get_slice/get_raw_slice
  # are the ratchet-to-C7 debt; runtime_view retires per §2.3.
  @banned_kind_calls [:get_slice, :get_raw_slice, :runtime_view]

  @ready_gate_allowed_fn :register_external_gate
  @process_generation_fn :current_process_generation

  # Banned `:sys` sidecar ops — read/write a live process's WHOLE internal state
  # (incl. a Kind's private authority). Flagged in every receiver form: literal
  # `:sys.op`, reflective `apply/3` / `:erlang.apply/3`, and a variable receiver
  # bound to `:sys` (`s = :sys; s.op(pid)`).
  @sys_banned [:get_state, :replace_state, :get_status]

  # Kind/actor PROTOCOL message verbs — the `:ezagent_*` atoms actually sent to
  # (and matched by) actor GenServers, enumerated from the `handle_call/cast/info`
  # clauses in the actor framework ∪ every `GenServer.call/cast`/`send` target
  # repo-wide. This is the taint-INDIRECTION allowlist: an assigned/relayed var
  # whose value carries one of these is a Kind message and taints (restoring the
  # broad indirect detection origin/main had — bare atoms, runtime-assembled
  # tuples). It deliberately EXCLUDES the many other `ezagent_`-prefixed atoms
  # that are OTP app names / ETS-table / Registry / config keys
  # (`:ezagent_domain_pty`, `:ezagent_role_registry`, `:ezagent_rate_limiter`, …)
  # — those are never Kind messages and must not taint. The DIRECT
  # `GenServer.call(pid, :ezagent_*)` arg check stays broad (see
  # `genserver_kind_message?/3`), so a direct send of any `:ezagent_*` message is
  # still flagged even if a new verb is not yet listed here.
  @kind_message_verbs MapSet.new([
                        :ezagent_detach,
                        :ezagent_dispatch,
                        :ezagent_em_reconcile,
                        :ezagent_external_ready_gate,
                        :ezagent_get_slice,
                        :ezagent_kind_module,
                        :ezagent_launch_context_relay,
                        :ezagent_lifecycle_destroy,
                        :ezagent_mount,
                        :ezagent_post_init,
                        :ezagent_presence_diff,
                        :ezagent_recover_settlements,
                        :ezagent_recredential_generation,
                        :ezagent_reply,
                        :ezagent_resolve_action_subject,
                        :ezagent_revoke_all_to,
                        :ezagent_run_deferred,
                        :ezagent_runtime_view,
                        :ezagent_validate_cap_artifact,
                        :ezagent_verify_cap_artifact,
                        :ezagent_worker_initial_subscribe,
                        :ezagent_worker_resubscribe_result,
                        :ezagent_worker_resubscribe_retry,
                        :ezagent_worker_subscribe_result
                      ])

  @doc """
  The repository root (absolute). Resolved from the working directory (the mix
  test / task cwd), NOT a compile-time `__DIR__` — this is a dev/CI source-tree
  scanner, not a shipped runtime asset (same idiom as `Mix.Tasks.Ezagent.Arch.Scan`).
  """
  def repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  # ── Public: scanned SITES ──────────────────────────────────────────────────

  # The gate's own machinery names the banned modules as DATA (the config below);
  # it is not a reach-in, so it is excluded from the forward scan.
  @gate_infra ~w(
    ezagent/actor_boundary_scanner.ex
    ezagent/actor_boundary_ledger.ex
  )

  @doc "All FORWARD reach-in sites currently in the tree (non-mover apps/*/lib)."
  @spec forward_sites() :: [map()]
  def forward_sites do
    root = repo_root()
    excluded = MapSet.new(@mover_files ++ @gate_infra, &Path.join([root, @core_lib, &1]))

    root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(excluded, &1))
    |> Enum.flat_map(fn abs ->
      rel = Path.relative_to(abs, root)
      forward_sites_in_source(File.read!(abs), rel)
    end)
  end

  @doc "All REVERSE upward-reference sites in the mover set."
  @spec reverse_sites() :: [map()]
  def reverse_sites do
    own = own_modules()
    root = repo_root()

    Enum.flat_map(@mover_files, fn rel ->
      path = Path.join([root, @core_lib, rel])
      reverse_sites_in_source(File.read!(path), Path.join(@core_lib, rel), own)
    end)
  end

  # ── Public: enforcement (ratchet) ──────────────────────────────────────────

  @doc """
  FORWARD sites present now but NOT covered by the frozen ledger — new debt.

  Enforcement is by MULTISET (frequency per identity), not a plain set, so
  ADDING a byte-identical reach-in line (same content SHA) to an already-
  allowlisted file still REDs: its identity's scanned count exceeds the ledger
  count. Content-anchored (line-independent) — resistant to unrelated insertions.
  """
  def forward_new_offenders,
    do: new_offenders(forward_sites(), forward_ratchet() ++ forward_fixed())

  @doc "FORWARD ratchet entries no longer present — stale (the ledger must shrink)."
  def forward_stale, do: stale(forward_sites(), forward_ratchet())

  @doc "Fixed process-generation consumer sites that are no longer present (door check)."
  def forward_fixed_missing do
    scanned = identities(forward_sites())
    Enum.reject(forward_fixed(), &MapSet.member?(scanned, identity(&1)))
  end

  @doc "REVERSE sites not covered by the frozen ledger — new upward-reference debt."
  def reverse_new_offenders,
    do: new_offenders(reverse_sites(), reverse_ratchet() ++ reverse_fixed())

  @doc "REVERSE ratchet entries no longer present — stale (the ledger must shrink)."
  def reverse_stale, do: stale(reverse_sites(), reverse_ratchet())

  @doc "The identity used for ratcheting — content-anchored, line-independent."
  def identity(%{path: path, target: target, sha: sha}), do: {path, target, sha}

  defp identities(sites), do: MapSet.new(sites, &identity/1)

  # Scanned occurrences of an identity that EXCEED its ledger allowance are new.
  @doc false
  def new_offenders(scanned, ledger) do
    allowed = Enum.frequencies_by(ledger, &identity/1)

    scanned
    |> Enum.group_by(&identity/1)
    |> Enum.flat_map(fn {id, sites} ->
      Enum.take(sites, max(length(sites) - Map.get(allowed, id, 0), 0))
    end)
  end

  # Ledger occurrences of an identity NOT matched by a scanned occurrence are stale.
  defp stale(scanned, ledger) do
    present = Enum.frequencies_by(scanned, &identity/1)

    ledger
    |> Enum.group_by(&identity/1)
    |> Enum.flat_map(fn {id, entries} ->
      Enum.take(entries, max(length(entries) - Map.get(present, id, 0), 0))
    end)
  end

  # ── FORWARD site detection ─────────────────────────────────────────────────

  @doc false
  def forward_sites_in_source(source, rel) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        bindings = message_bindings(ast)
        destructures = destructure_bindings(ast)
        msg_fns = kind_message_fns(ast)

        ctx = %{
          aliases: collect_aliases(ast),
          msg_fns: msg_fns,
          tainted: kind_message_vars(ast, bindings, destructures, msg_fns),
          sys_vars: sys_vars(bindings)
        }

        lines = String.split(source, "\n")

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, forward_offense(node, ctx) ++ acc}
          end)

        hits
        |> Enum.map(fn %{target: t, line: l} ->
          %{path: rel, target: t, line: l, sha: line_sha(lines, l)}
        end)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  # Qualified calls.
  # `:sys.get_state/replace_state/get_status` — reads/writes a live process's
  # WHOLE internal state, incl. a Kind's private authority (kind/server.ex:12).
  # Kind pids are handed out by the public §2.2 surface (list_instances/0,
  # spawn/3), so an un-gated :sys reach is an actor-state bypass. MUST precede
  # the general call clause (which would otherwise match `:sys` as the receiver
  # and drop it). Non-Kind sidecar :sys calls are allowlisted DEBT in the ledger.
  defp forward_offense({{:., _, [:sys, fun]}, meta, _args}, _ctx)
       when fun in @sys_banned do
    [hit(":sys.#{fun}", meta)]
  end

  # Reflective `:sys` via `:erlang.apply(mod, op, args)` — mod is `:sys` or a
  # variable bound to `:sys`. Precedes the general qualified clause (which would
  # otherwise resolve `:erlang.apply` to a benign no-op).
  defp forward_offense({{:., _, [:erlang, :apply]}, meta, [modarg, op, _a]}, %{sys_vars: sv})
       when is_atom(op) and op in @sys_banned do
    if sys_receiver?(modarg, sv), do: [hit(":sys.#{op}", meta)], else: []
  end

  # Reflective `:sys` via a variable receiver — `s = :sys; s.get_state(pid)`.
  # Scoped to the banned ops so it never shadows a non-sys var call (which the
  # general clause resolves to nil anyway).
  defp forward_offense({{:., _, [{v, _, vctx}, fun]}, meta, _args}, %{sys_vars: sv})
       when is_atom(v) and (is_atom(vctx) or is_nil(vctx)) and fun in @sys_banned do
    if MapSet.member?(sv, v), do: [hit(":sys.#{fun}", meta)], else: []
  end

  # Qualified calls.
  defp forward_offense({{:., _, [modast, fun]}, meta, args}, ctx)
       when is_atom(fun) and is_list(args) do
    %{aliases: aliases, tainted: tainted, msg_fns: msg_fns} = ctx
    module = resolve_ast(modast, aliases)

    cond do
      fun in @banned_kind_calls and module == Ezagent.Kind ->
        [hit("Kind.#{fun}", meta)]

      fun != @ready_gate_allowed_fn and module == Ezagent.ReadyGate ->
        [hit("ReadyGate.#{fun}", meta)]

      fun == @process_generation_fn and module == Ezagent.Cap.Authority ->
        [hit("Cap.Authority.current_process_generation", meta)]

      fun in [:call, :cast] and module == GenServer and
          genserver_kind_message?(args, tainted, msg_fns) ->
        [hit("GenServer.#{fun}(:ezagent_*)", meta)]

      banned_internal_root?(module) ->
        [hit(short(module), meta)]

      true ->
        []
    end
  end

  # Reflective `:sys` via bare `apply(mod, op, args)` — mod is `:sys` or a
  # `:sys`-bound variable.
  defp forward_offense({:apply, meta, [modarg, op, _a]}, %{sys_vars: sv})
       when is_atom(op) and op in @sys_banned do
    if sys_receiver?(modarg, sv), do: [hit(":sys.#{op}", meta)], else: []
  end

  # Bare/aliased reference to a banned internal root (data tables, specs, structs).
  defp forward_offense({:__aliases__, meta, parts}, %{aliases: aliases}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = resolve(parts, aliases)
      if banned_internal_root?(module), do: [hit(short(module), meta)], else: []
    else
      []
    end
  end

  defp forward_offense(_node, _ctx), do: []

  # The `:sys` receiver of a reflective apply — the literal atom or a var bound
  # to it (`s = :sys`).
  defp sys_receiver?(:sys, _sv), do: true

  defp sys_receiver?({v, _, vctx}, sv) when is_atom(v) and (is_atom(vctx) or is_nil(vctx)),
    do: MapSet.member?(sv, v)

  defp sys_receiver?(_other, _sv), do: false

  # A GenServer message is a Kind reach-in when an argument is:
  #   • a DIRECT `:ezagent_*` message — inline atom or tuple (broad, unchanged
  #     from origin/main: `GenServer.call(pid, :ezagent_runtime_view)` /
  #     `{:ezagent_get_slice, k}`; a direct send of any `:ezagent_*` message is
  #     flagged even if its verb is not in `@kind_message_verbs`);
  #   • a tainted variable, or an access-path (`payload.m` / `payload[:m]` /
  #     `Map.fetch!(payload, :m)` / `elem(payload, i)`) rooted at one; or
  #   • the direct result of a message-producing local helper.
  # The INDIRECT forms restrict the taint ORIGIN to the `@kind_message_verbs`
  # protocol allowlist so config/ETS/app-name atoms (`:ezagent_domain_pty`,
  # `:ezagent_role_registry`) never mislabel a benign call — WITHOUT weakening
  # detection of real assigned/relayed message values.
  defp genserver_kind_message?(args, tainted, msg_fns) do
    args_have_ezagent_atom?(args) or
      Enum.any?(args, fn arg ->
        var_tainted?(arg, tainted) or calls_message_fn?(arg, msg_fns)
      end)
  end

  # ── Kind-message taint (§C0 hardening) ──────────────────────────────────────
  #
  # A value is Kind-TAINTED when it carries/produces an `:ezagent_*` Kind message.
  # `kind_message_vars/3` computes the set of tainted variable NAMES (module-wide,
  # matching the existing binding-merge granularity) as a fixpoint over three
  # sources, closing the constructed evasions codex flagged:
  #
  #   • direct/alias bindings — `msg = {:ezagent_*}`, `fwd = msg`;
  #   • helper-return chains of ANY depth — `m = a()` where a→b→{:ezagent_*}
  #     (via the `kind_message_fns/1` call-graph fixpoint);
  #   • interprocedural parameter relay — a tainted argument at a local call site
  #     taints the matching positional parameter of the callee, so a
  #     `GenServer.call(p, m)` inside `defp relay(p, m)` is flagged.
  #
  # Access-path extraction (`payload.m`, `payload[:m]`, `Map.fetch!(payload, :m)`,
  # `elem(payload, i)`) is resolved at the use site by `var_root/1`; simple
  # destructuring (`{:box, msg} = payload`) is handled by `destructures`.
  defp kind_message_vars(ast, bindings, destructures, msg_fns) do
    params = fn_params(ast)
    calls = local_calls(ast)
    taint_fixpoint(bindings, destructures, params, calls, msg_fns, MapSet.new())
  end

  defp taint_fixpoint(bindings, destructures, params, calls, msg_fns, tainted) do
    # (1) binding names whose RHS is tainted.
    after_binds =
      Enum.reduce(bindings, tainted, fn {name, rhs}, acc ->
        if tainted_value?(rhs, acc, msg_fns), do: MapSet.put(acc, name), else: acc
      end)

    # (1b) simple destructuring — a tainted RHS taints every var in the pattern.
    after_destructure =
      Enum.reduce(destructures, after_binds, fn {pvars, rhs}, acc ->
        if tainted_value?(rhs, acc, msg_fns), do: Enum.into(pvars, acc), else: acc
      end)

    # (2) parameters that receive a tainted argument at any local call site.
    next =
      Enum.reduce(calls, after_destructure, fn {name, arity, args}, acc ->
        params
        |> Map.get({name, arity}, [])
        |> Enum.reduce(acc, fn plist, a1 ->
          plist
          |> Enum.zip(args)
          |> Enum.reduce(a1, fn
            {pname, arg}, a2 when is_atom(pname) and pname != nil ->
              if tainted_value?(arg, a2, msg_fns), do: MapSet.put(a2, pname), else: a2

            {_pattern_param, _arg}, a2 ->
              a2
          end)
        end)
      end)

    if MapSet.equal?(next, tainted),
      do: tainted,
      else: taint_fixpoint(bindings, destructures, params, calls, msg_fns, next)
  end

  # A value carries/produces a Kind message: it mentions a `@kind_message_verbs`
  # protocol atom anywhere (bare atom, `{:ezagent_*, …}` tuple, or a runtime-
  # assembled tuple like `List.to_tuple([:ezagent_get_slice, k])` — this is the
  # broad indirect origin origin/main had), is a tainted variable/access-path, or
  # calls a message-producing helper. Restricting the ORIGIN to the protocol-verb
  # allowlist (not "any `:ezagent_*` atom") is what excludes the config/ETS/
  # app-name false positives (`:ezagent_domain_pty`, `:ezagent_role_registry`),
  # WITHOUT weakening detection of real message values.
  defp tainted_value?(expr, tainted, msg_fns) do
    carries_kind_message?(expr) or
      var_tainted?(expr, tainted) or
      calls_message_fn?(expr, msg_fns)
  end

  # `expr` mentions a Kind-protocol message verb (`@kind_message_verbs`) anywhere
  # within it — bare atom or nested inside a tuple/list/map. App/ETS/config atoms
  # that merely share the `ezagent_` prefix are excluded by the allowlist.
  defp carries_kind_message?(expr) do
    {_, found?} =
      Macro.prewalk(expr, false, fn
        atom, acc when is_atom(atom) -> {atom, acc or MapSet.member?(@kind_message_verbs, atom)}
        node, acc -> {node, acc}
      end)

    found?
  end

  # A bare variable, or an access-path rooted at a tainted var: dot (`a.b.c`),
  # index (`a[:k]`), `Map.fetch!/fetch/get(a, k)`, or `elem(a, i)`. Closes the
  # common field-extraction evasions; exotic extractors are tracked follow-up.
  defp var_tainted?(expr, tainted) do
    case var_root(expr) do
      name when is_atom(name) -> MapSet.member?(tainted, name)
      _ -> false
    end
  end

  defp var_root({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)), do: name
  defp var_root({{:., _, [Access, :get]}, _, [inner | _]}), do: var_root(inner)

  defp var_root({{:., _, [{:__aliases__, _, [:Map]}, f]}, _, [inner | _]})
       when f in [:fetch!, :fetch, :get],
       do: var_root(inner)

  defp var_root({:elem, _, [inner | _]}), do: var_root(inner)
  defp var_root({{:., _, [inner, field]}, _, _}) when is_atom(field), do: var_root(inner)
  defp var_root(_expr), do: nil

  # Local function names that (transitively) PRODUCE a Kind message. Base: a body
  # that mentions a protocol message verb. Fixpoint: a body that CALLS a producer
  # is itself a producer — this is what closes helper-chains ≥2 deep.
  defp kind_message_fns(ast) do
    defs = fn_bodies(ast)
    base = for {name, body} <- defs, carries_kind_message?(body), into: MapSet.new(), do: name
    msg_fns_fixpoint(defs, base)
  end

  defp msg_fns_fixpoint(defs, fns) do
    next =
      Enum.reduce(defs, fns, fn {name, body}, acc ->
        if MapSet.member?(acc, name) or not calls_message_fn?(body, acc),
          do: acc,
          else: MapSet.put(acc, name)
      end)

    if MapSet.equal?(next, fns), do: fns, else: msg_fns_fixpoint(defs, next)
  end

  defp calls_message_fn?(expr, msg_fns) do
    {_, found?} =
      Macro.prewalk(expr, false, fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or MapSet.member?(msg_fns, name)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # `{name, body}` for every local def/defp clause (body = the `[do: …]` kwlist).
  defp fn_bodies(ast) do
    {_, out} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] and is_list(body) ->
          case fn_name(head) do
            name when is_atom(name) -> {node, [{name, body} | acc]}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    out
  end

  # `{name, arity} => [param_name_list]` for every local def/defp clause. Each
  # position holds its bare-var name, or nil for a pattern (no single var binds).
  defp fn_params(ast) do
    {_, out} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] and is_list(body) ->
          case fn_signature(head) do
            {name, plist} ->
              {node, Map.update(acc, {name, length(plist)}, [plist], &[plist | &1])}

            nil ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    out
  end

  defp fn_signature({:when, _, [inner | _]}), do: fn_signature(inner)

  defp fn_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, Enum.map(args, &param_name/1)}

  defp fn_signature(_head), do: nil

  defp param_name({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)), do: name
  defp param_name(_pattern), do: nil

  # `{name, arity, args}` for every bare local-style call INSIDE a function body.
  # Over-collection is harmless — only names present in `fn_params` contribute to
  # propagation. Heads are excluded so a formal-parameter pattern (which is not
  # data flow) never spuriously taints a multi-clause function's parameters.
  defp local_calls(ast) do
    Enum.flat_map(body_asts(ast), fn body ->
      {_, out} =
        Macro.prewalk(body, [], fn
          {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
            {node, [{name, length(args), args} | acc]}

          node, acc ->
            {node, acc}
        end)

      out
    end)
  end

  # The `[do: …]` body kwlist of every def/defp clause — the taint analysis
  # considers assignments and calls that occur in BODIES only, never the
  # formal-parameter patterns of a head.
  defp body_asts(ast) do
    {_, out} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_head, body]} = node, acc when kind in [:def, :defp] and is_list(body) ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    out
  end

  defp fn_name({:when, _, [inner | _]}), do: fn_name(inner)
  defp fn_name({name, _, _}) when is_atom(name), do: name
  defp fn_name(_), do: nil

  # Every `var = rhs` binding inside a function body (heads excluded — a `%{} = x`
  # pattern in a head is destructuring, not data flow).
  defp message_bindings(ast) do
    Enum.flat_map(body_asts(ast), fn body ->
      {_, binds} =
        Macro.prewalk(body, [], fn
          {:=, _, [{name, _, ctx}, rhs]} = node, acc
          when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
            {node, [{name, rhs} | acc]}

          node, acc ->
            {node, acc}
        end)

      binds
    end)
  end

  # `{pattern_vars, rhs}` for every DESTRUCTURING `pattern = rhs` in a body — a
  # non-bare-var LHS (`{:box, msg} = payload`, `%{m: msg} = payload`). A tainted
  # RHS taints every var the pattern binds. (Bare-var `=` is `message_bindings`.)
  defp destructure_bindings(ast) do
    Enum.flat_map(body_asts(ast), fn body ->
      {_, binds} =
        Macro.prewalk(body, [], fn
          {:=, _, [{name, _, ctx}, _rhs]} = node, acc
          when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
            {node, acc}

          {:=, _, [lhs, rhs]} = node, acc ->
            case pattern_vars(lhs) do
              [] -> {node, acc}
              pvars -> {node, [{pvars, rhs} | acc]}
            end

          node, acc ->
            {node, acc}
        end)

      binds
    end)
  end

  # The bound variable names in a match pattern (`_` and pattern operators skipped).
  defp pattern_vars(pattern) do
    {_, vars} =
      Macro.prewalk(pattern, [], fn
        {name, _, ctx} = node, acc
        when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and name != :_ ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # Variable names bound to the `:sys` atom (`s = :sys`), propagated across
  # `t = s` alias chains — the receivers of a reflective `:sys` call.
  defp sys_vars(bindings) do
    seed = for {name, rhs} <- bindings, rhs == :sys, into: MapSet.new(), do: name
    alias_fixpoint(bindings, seed)
  end

  # Propagate a var-set across `x = y` alias chains until fixpoint.
  defp alias_fixpoint(bindings, vars) do
    next =
      Enum.reduce(bindings, vars, fn
        {name, {v, _, ctx}}, acc when is_atom(v) and (is_atom(ctx) or is_nil(ctx)) ->
          if MapSet.member?(acc, v), do: MapSet.put(acc, name), else: acc

        {_name, _rhs}, acc ->
          acc
      end)

    if MapSet.equal?(next, vars), do: vars, else: alias_fixpoint(bindings, next)
  end

  defp banned_internal_root?(nil), do: false

  defp banned_internal_root?(module) do
    MapSet.member?(@banned_internal_modules, module) or
      String.starts_with?(Atom.to_string(module), @banned_internal_prefix)
  end

  defp args_have_ezagent_atom?(args) do
    {_, found?} =
      Macro.prewalk(args, false, fn
        atom, acc when is_atom(atom) ->
          {atom, acc or String.starts_with?(Atom.to_string(atom), "ezagent_")}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # ── REVERSE site detection ─────────────────────────────────────────────────

  @doc false
  def reverse_sites_in_source(source, rel, own) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)
        lines = String.split(source, "\n")

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, reverse_reference_hit(node, aliases, own) ++ acc}
          end)

        hits
        |> Enum.map(fn %{module: m, line: l} ->
          %{path: rel, target: short(m), module: m, line: l, sha: line_sha(lines, l)}
        end)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp reverse_reference_hit({:__aliases__, meta, parts}, aliases, own) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = resolve(parts, aliases)

      if reverse_staying_core?(module) and not MapSet.member?(own, module) do
        [%{module: module, line: Keyword.get(meta, :line, 0)}]
      else
        []
      end
    else
      []
    end
  end

  defp reverse_reference_hit(_node, _aliases, _own), do: []

  defp reverse_staying_core?(module) do
    s = Atom.to_string(module)
    String.starts_with?(s, "Elixir.Ezagent.") or String.starts_with?(s, "Elixir.EzagentCore.")
  end

  @doc "Every module DEFINED in the mover set (self-references, never offenders)."
  def own_modules do
    root = repo_root()

    Enum.reduce(@mover_files, MapSet.new(), fn rel, acc ->
      path = Path.join([root, @core_lib, rel])

      case Code.string_to_quoted(File.read!(path)) do
        {:ok, ast} ->
          {_, mods} =
            Macro.prewalk(ast, acc, fn
              {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, a ->
                {node, MapSet.put(a, Module.concat(parts))}

              node, a ->
                {node, a}
            end)

          mods

        {:error, _} ->
          acc
      end
    end)
  end

  # ── Shared AST helpers ─────────────────────────────────────────────────────

  defp hit(target, meta), do: %{target: target, line: Keyword.get(meta, :line, 0)}

  defp line_sha(lines, line) do
    lines
    |> Enum.at(line - 1, "")
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp short(module), do: module |> Module.split() |> Enum.join(".")

  defp resolve_ast({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: resolve(parts, aliases), else: nil
  end

  defp resolve_ast(mod, _aliases) when is_atom(mod), do: mod
  defp resolve_ast(_other, _aliases), do: nil

  defp resolve([first | rest], aliases) do
    parts =
      case Map.get(aliases, first) do
        nil -> [first | rest]
        full -> full ++ rest
      end

    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, kids}]} = node, acc
        when is_list(kids) ->
          acc =
            Enum.reduce(kids, acc, fn
              {:__aliases__, _, [last]}, a -> Map.put(a, last, prefix ++ [last])
              _, a -> a
            end)

          {node, acc}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} -> {node, Map.put(acc, as_name, parts)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # ── Frozen ledgers (site fingerprints) ─────────────────────────────────────
  # The big data lives in `Ezagent.ActorBoundaryLedger`, seeded from the
  # empty-allowlist enumerator (see the ExUnit gate + §4.4/§3.4).
  @doc false
  defdelegate forward_ratchet(), to: Ezagent.ActorBoundaryLedger
  @doc false
  defdelegate forward_fixed(), to: Ezagent.ActorBoundaryLedger
  @doc false
  defdelegate reverse_ratchet(), to: Ezagent.ActorBoundaryLedger
  @doc false
  defdelegate reverse_fixed(), to: Ezagent.ActorBoundaryLedger
end
