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
        aliases = collect_aliases(ast)
        kind_msg_vars = kind_message_vars(ast)
        lines = String.split(source, "\n")

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, forward_offense(node, aliases, kind_msg_vars) ++ acc}
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
  defp forward_offense({{:., _, [:sys, fun]}, meta, _args}, _aliases, _kmv)
       when fun in [:get_state, :replace_state, :get_status] do
    [hit(":sys.#{fun}", meta)]
  end

  # Qualified calls.
  defp forward_offense({{:., _, [modast, fun]}, meta, args}, aliases, kind_msg_vars)
       when is_atom(fun) and is_list(args) do
    module = resolve_ast(modast, aliases)

    cond do
      fun in @banned_kind_calls and module == Ezagent.Kind ->
        [hit("Kind.#{fun}", meta)]

      fun != @ready_gate_allowed_fn and module == Ezagent.ReadyGate ->
        [hit("ReadyGate.#{fun}", meta)]

      fun == @process_generation_fn and module == Ezagent.Cap.Authority ->
        [hit("Cap.Authority.current_process_generation", meta)]

      fun in [:call, :cast] and module == GenServer and
          genserver_kind_message?(args, kind_msg_vars) ->
        [hit("GenServer.#{fun}(:ezagent_*)", meta)]

      banned_internal_root?(module) ->
        [hit(short(module), meta)]

      true ->
        []
    end
  end

  # Bare/aliased reference to a banned internal root (data tables, specs, structs).
  defp forward_offense({:__aliases__, meta, parts}, aliases, _kmv) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = resolve(parts, aliases)
      if banned_internal_root?(module), do: [hit(short(module), meta)], else: []
    else
      []
    end
  end

  defp forward_offense(_node, _aliases, _kmv), do: []

  # A GenServer message is a Kind reach-in when it carries an `:ezagent_*` atom
  # inline OR is a variable bound to such a message (indirect form).
  defp genserver_kind_message?(args, kind_msg_vars) do
    args_have_ezagent_atom?(args) or
      Enum.any?(args, fn
        {name, _, ctx} when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
          MapSet.member?(kind_msg_vars, name)

        _ ->
          false
      end)
  end

  # Variable names bound to a message that contains an `:ezagent_*` atom.
  # Variable names that (transitively) carry an `:ezagent_*` Kind message —
  # closing the multi-hop evasions: `msg = {:ezagent_*}; fwd = msg; call(pid, fwd)`
  # (alias chains) and `msg = build_msg()` where a local helper returns an
  # `:ezagent_*` tuple.
  defp kind_message_vars(ast) do
    msg_fns = kind_message_fns(ast)
    bindings = message_bindings(ast)

    seed =
      for {name, rhs} <- bindings, rhs_taints?(rhs, msg_fns), into: MapSet.new(), do: name

    taint_fixpoint(bindings, seed)
  end

  # Local function names whose BODY mentions an `:ezagent_*` atom — conservatively
  # treated as producing a Kind message (a call to one taints its result).
  defp kind_message_fns(ast) do
    {_, fns} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case fn_name(head) do
            name when is_atom(name) ->
              if args_have_ezagent_atom?([body]),
                do: {node, MapSet.put(acc, name)},
                else: {node, acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    fns
  end

  defp fn_name({:when, _, [inner | _]}), do: fn_name(inner)
  defp fn_name({name, _, _}) when is_atom(name), do: name
  defp fn_name(_), do: nil

  # All `var = rhs` bindings in the file.
  defp message_bindings(ast) do
    {_, binds} =
      Macro.prewalk(ast, [], fn
        {:=, _, [{name, _, ctx}, rhs]} = node, acc
        when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
          {node, [{name, rhs} | acc]}

        node, acc ->
          {node, acc}
      end)

    binds
  end

  # An RHS taints if it directly carries an `:ezagent_*` atom OR calls a
  # kind-message-producing local helper.
  defp rhs_taints?(rhs, msg_fns) do
    args_have_ezagent_atom?([rhs]) or calls_message_fn?(rhs, msg_fns)
  end

  defp calls_message_fn?(rhs, msg_fns) do
    {_, found?} =
      Macro.prewalk(rhs, false, fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, acc or MapSet.member?(msg_fns, name)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # Propagate taint across `x = y` alias chains until fixpoint.
  defp taint_fixpoint(bindings, tainted) do
    next =
      Enum.reduce(bindings, tainted, fn
        {name, {v, _, ctx}}, acc when is_atom(v) and (is_atom(ctx) or is_nil(ctx)) ->
          if MapSet.member?(acc, v), do: MapSet.put(acc, name), else: acc

        {_name, _rhs}, acc ->
          acc
      end)

    if MapSet.equal?(next, tainted), do: tainted, else: taint_fixpoint(bindings, next)
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
