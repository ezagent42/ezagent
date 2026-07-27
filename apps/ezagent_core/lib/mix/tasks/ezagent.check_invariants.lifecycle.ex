defmodule Mix.Tasks.Ezagent.CheckInvariants.Lifecycle do
  @shortdoc "Phase C HARD gates: Lifecycle is the sole developer surface + §11 naming lints"

  @moduledoc """
  > **CLI/GUI parity audit carve-out — dev-loop tool (Category A).**
  > Like `mix ezagent.check_invariants`, this is a source-tree grep gate
  > that runs WITHOUT the runtime BEAM. It stays as `mix ezagent.*`; do
  > NOT migrate it to a dispatched `mix ezagent` op.

  Phase C of the Lifecycle migration (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5 +
  §8 AC-1 + §11). HARD-fails CI when the retired developer surface
  reappears in a developer-tier file, and when a `ezagent_core` module
  name leaks an upper-layer concept (NP-2) or a generic-name single-
  action Lifecycle module over-promises (NP-3).

  These gates encode `feedback_completion_requires_invariant_test`: the
  gate IS the architectural invariant test. Phase B is already clean, so
  every gate here passes today; the point is that a regression fails fast.

  ## Developer-tier scope

  A "developer-tier" file is any `.ex` under:

  - `apps/ezagent_domain_*/lib/`
  - `apps/ezagent_plugin_*/lib/`
  - `apps/ezagent_core/lib/` and `apps/ezagent_actor/lib/` MINUS the engine
    allowlist (the four modules that legitimately reference the engine
    surface or compile down to it):
    - `apps/ezagent_actor/lib/ezagent/behavior.ex` — the engine macro
    - `apps/ezagent_actor/lib/ezagent/kind/runtime.ex` — the executor
    - `apps/ezagent_actor/lib/ezagent/lifecycle.ex` — the Lifecycle macro
      (it EMITS `use Ezagent.ActionSet` + `init_slice`/`state_slice`/
      `post_init`/`handle_continue`/`on_ready` underneath — R10-3)
    - `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`

  Tests (`test/`, `*_test.exs`, `test/support/*.ex`) are NOT
  developer-tier production code: engine fixtures there legitimately
  `use Ezagent.ActionSet` directly to exercise the engine, so they are
  excluded.

  ## What it does NOT delete / gate

  Per SPEC §10 R10-3, the engine contract `Ezagent.ActionSet` STAYS —
  these gates scope to developer-tier files and exempt the engine
  allowlist. AC-5 "no shims" means no developer-facing back-compat, NOT
  removal of the engine contract.

  ## Exit semantics

  Exit `0` = all gates pass. Exit non-zero = at least one violation;
  stderr names the failing gate + the offending file:line.
  """
  use Mix.Task

  # The four engine modules exempt from the developer-surface gates.
  # Anchored on the relative path so a substring match is unambiguous.
  @engine_allowlist [
    "apps/ezagent_actor/lib/ezagent/behavior.ex",
    "apps/ezagent_actor/lib/ezagent/kind/runtime.ex",
    "apps/ezagent_actor/lib/ezagent/lifecycle.ex",
    "apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex"
  ]

  # §11 NP-2 layer-vocabulary lint: a module under apps/ezagent_core/ must
  # not name an upper-layer composition concept. Allowlist holds genuine
  # exceptions (cross-cutting plumbing that legitimately names the concept,
  # plus the engine files that document the words in moduledocs).
  @layer_vocab_words ~w(Agent Session Orchestrator Workspace Worker Feishu Cc Codex Np Curl)

  # NP-2 allowlist — core modules whose name contains a flagged word for a
  # legitimate, pre-existing structural reason. Each entry MUST be
  # justified. These are core-layer REGISTRIES/INDEXES that hold the
  # named concept's URIs/facts as opaque DATA (invariants 4 & 18 & the
  # #114 AgentLineage index), NOT upper-layer compositions the core module
  # owns. They predate §11; renaming them touches snapshot/registry keys
  # across the tree and is out of Phase C scope. Flagged for a future
  # naming pass, allowlisted (not silently renamed) per §11 Phase B audit
  # rule ("a rename touches call sites + snapshot slice keys").
  @layer_vocab_allowlist [
    # WorkspaceRegistry — invariant 4 SoT: the workspace-URI→pid registry
    # (workspace scoping enforced here). Holds workspace URIs as keys.
    "apps/ezagent_core/lib/ezagent/workspace_registry.ex",
    # AgentLineage — #114 lineage INDEX (agent_uri → spawned_by_uri),
    # rebuilt as a transient in the Agent's activate. A pure index over
    # opaque URIs.
    "apps/ezagent_core/lib/ezagent/agent_lineage.ex",
    # Agent.Materializer — core provisioning helper for template
    # materialization; this is cross-cutting infrastructure used by
    # plugin template classes, not a concrete upper-layer Agent Kind.
    "apps/ezagent_core/lib/ezagent/agent/materializer.ex",
    # Agent credential adapters — core credential cascade seam. They
    # adapt persisted credential facts into template materialization
    # data; they do not own Agent runtime behavior.
    "apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex",
    "apps/ezagent_core/lib/ezagent/agent/credential_slice_adapter.ex",
    # Agent.Recipe (+ Compose + CapMint) — the flavor-agnostic sandbox-content
    # RECIPE struct + its context-free composition + fail-closed cap minting
    # (task #54; symbol rename #127: Ezagent.Role → Ezagent.Agent.Recipe). This
    # is the core validation boundary over opaque recipe facts; it does not own
    # Agent runtime behavior. "Agent" names the namespace the rename landed on
    # (mirrors Agent.Materializer / AgentManifest); it is allowlisted, not
    # silently renamed, per the §11 Phase B audit rule (a rename touches call
    # sites + snapshot slice keys).
    "apps/ezagent_core/lib/ezagent/agent/recipe.ex",
    "apps/ezagent_core/lib/ezagent/agent/recipe/compose.ex",
    "apps/ezagent_core/lib/ezagent/agent/recipe/cap_mint.ex",
    # WorkspaceSharedSource — core credential source row schema for
    # workspace-scoped sharing; this is data vocabulary, not Workspace
    # behavior ownership.
    "apps/ezagent_core/lib/ezagent/credential/workspace_shared_source.ex",
    # AgentManifest — core declarative data schema used to compile an agent body
    # into template content across flavors. It validates opaque author/executor
    # facts; it does not own Agent runtime behavior.
    "apps/ezagent_core/lib/ezagent/agent_manifest.ex",
    "apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex",
    # WorkspaceOwnerGate / WorkspacePlacement — locality infrastructure over
    # workspace URIs. They decide runtime ownership for dispatch/spawn/session
    # chokepoints, not Workspace domain behavior.
    "apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex",
    "apps/ezagent_core/lib/ezagent/workspace_placement.ex",
    "apps/ezagent_core/lib/ezagent/workspace_placement/local_resolver.ex",
    # Session.SliceMigration + its mix task — one-shot chat→session snapshot
    # slice-key cutover (Allen 2026-06-12). Operates on core `kind_snapshots`
    # rows (same layer as `KindBaseBackfill`); "Session" names the SLICE KEY
    # being renamed, not an upper-layer Session Kind/runtime composition. A
    # migration tool that mentions the data it migrates, not a runtime owner.
    "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
    "apps/ezagent_core/lib/mix/tasks/ezagent.session.migrate_slice.ex"
  ]

  # NP-3 width lint: a generic lifecycle/admin/manager module name that
  # declares <= 1 action is a smell (the `Lifecycle`-with-one-`:terminate`
  # pattern that became `Terminable`). These are the generic name tokens.
  @generic_name_tokens ~w(Lifecycle Admin Manager Control Handler Service Worker Util Helper)

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("ezagent.check_invariants.lifecycle — Phase C gates active")

    files = developer_tier_files()

    failures =
      [
        gate_no_use_behavior(files),
        gate_no_init_slice(files),
        gate_no_state_slice_def(files),
        gate_no_boot_hooks(files),
        gate_no_invoke_callback(files),
        gate_no_engine_internals(files),
        gate_layer_vocab_lint(),
        gate_width_lint(files)
      ]
      |> Enum.reject(&match?(:ok, &1))

    if failures == [] do
      Mix.shell().info("  ✓ all Phase C lifecycle + naming gates clean")
      :ok
    else
      Enum.each(failures, fn {:error, name, output} ->
        Mix.shell().error("  ✗ #{name} VIOLATION:")
        Mix.shell().error(output)
      end)

      Mix.raise("ezagent.check_invariants.lifecycle: #{length(failures)} gate(s) violated")
    end
  end

  # ----------------------------------------------------------------------
  # Developer-tier file enumeration
  # ----------------------------------------------------------------------

  @doc false
  def developer_tier_files do
    domain_plugin =
      Path.wildcard("apps/ezagent_{domain,plugin}_*/lib/**/*.ex")

    actor =
      "apps/ezagent_actor/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&engine_allowlisted?/1)

    core =
      "apps/ezagent_core/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&engine_allowlisted?/1)

    (domain_plugin ++ actor ++ core)
    |> Enum.reject(&test_support_file?/1)
    |> Enum.sort()
  end

  defp engine_allowlisted?(path), do: path in @engine_allowlist

  # test/ dirs are surfaced by neither wildcard (we glob lib/), but guard
  # anyway in case a stray support file lands under lib.
  defp test_support_file?(path) do
    String.contains?(path, "/test/") or String.ends_with?(path, "_test.exs")
  end

  # ----------------------------------------------------------------------
  # Gate 1 — no developer-tier `use Ezagent.ActionSet` (must be Lifecycle)
  # SPEC §5 / AC-1. Anchored to the directive, not moduledoc/comment
  # mentions: `^\s*use Ezagent.ActionSet` with a word boundary so
  # `Ezagent.ActionSet.Session` etc. in prose are not matched.
  # ----------------------------------------------------------------------
  defp gate_no_use_behavior(files) do
    re = ~r/^\s*use\s+Ezagent\.Behavior\b/

    files
    |> hits(re)
    |> result(
      "gate_no_use_behavior (developer file must `use Ezagent.Lifecycle`)",
      "  ✓ no developer-tier `use Ezagent.ActionSet` (Lifecycle is sole surface)"
    )
  end

  # ----------------------------------------------------------------------
  # Gate 2 — no developer `def init_slice` (replaced by `create/1`).
  # ----------------------------------------------------------------------
  defp gate_no_init_slice(files) do
    re = ~r/^\s*def\s+init_slice\b/

    files
    |> hits(re)
    |> result(
      "gate_no_init_slice (replaced by `create/1`)",
      "  ✓ no developer-tier `def init_slice` (use `create/1`)"
    )
  end

  # ----------------------------------------------------------------------
  # Gate 3 — no hand-rolled `def state_slice` in developer modules.
  # The snapshot-compat override is the macro OPTION
  # `use Ezagent.Lifecycle, state_slice: :x` carrying a
  # `# lifecycle:state_slice_override` marker — NOT a `def state_slice`.
  # A bare `def state_slice` reappearing means the author hand-rolled it.
  # ----------------------------------------------------------------------
  defp gate_no_state_slice_def(files) do
    re = ~r/^\s*def\s+state_slice\b/

    files
    |> hits(re)
    |> result(
      "gate_no_state_slice_def (macro auto-derives; override via `state_slice:` opt + `# lifecycle:state_slice_override` marker)",
      "  ✓ no developer-tier `def state_slice` (macro-derived or marked override)"
    )
  end

  # ----------------------------------------------------------------------
  # Gate 4 — no LIFECYCLE-module boot hooks folded into `activate`:
  # `post_init` / `handle_continue` / `on_ready` / `reconcile_after_load`.
  # The macro EMITS these in lifecycle.ex; a `use Ezagent.Lifecycle`
  # module that ALSO hand-rolls one bypassed the unified `activate` path.
  # SCOPED to Lifecycle Behavior modules only — plain developer GenServers
  # (e.g. pty/server.ex, presence_fanout.ex, boot_reconciler.ex) use
  # `handle_continue` legitimately as an OTP callback and are NOT in scope.
  # ----------------------------------------------------------------------
  defp gate_no_boot_hooks(files) do
    re = ~r/^\s*def\s+(post_init|handle_continue|on_ready|reconcile_after_load)\b/

    files
    |> Enum.filter(&lifecycle_module?/1)
    |> hits(re)
    |> result(
      "gate_no_boot_hooks (a Lifecycle module must not hand-roll post_init/handle_continue/on_ready/reconcile_after_load — folded into `activate`/`activated`/`handle_signal`)",
      "  ✓ no Lifecycle-module legacy boot hooks (folded into activate/activated/handle_signal)"
    )
  end

  # ----------------------------------------------------------------------
  # Gate 5 — no retired `invoke/4` Behavior callback.
  # Scoped to the 4-ARITY callback signature `def invoke(_, _, _, _)` so
  # unrelated `invoke/2` fns (orchestrator tools.ex `invoke(tool, args)`,
  # api_v1_controller.ex `invoke(conn, params)`) are NOT matched.
  # ----------------------------------------------------------------------
  defp gate_no_invoke_callback(files) do
    # `def invoke(` followed by exactly 4 comma-separated args before `)`.
    # Permissive on arg shape (pattern matches/guards), strict on arity:
    # three top-level commas inside the paren group.
    re = ~r/^\s*def\s+invoke\(\s*[^(),]+,\s*[^(),]+,\s*[^(),]+,\s*[^()]+\)/

    files
    |> hits(re)
    |> result(
      "gate_no_invoke_callback (retired Behavior `invoke/4` must not reappear)",
      "  ✓ no developer-tier `invoke/4` callback (retired)"
    )
  end

  # ----------------------------------------------------------------------
  # Gate 6 — no direct engine internals reached from inside a LIFECYCLE
  # HANDLER: `Ezagent.Invocation.dispatch(` / `Ezagent.SnapshotStore.` /
  # `Ezagent.EventLog.append(`. (SPEC §5: these were already §11 gates,
  # "inside a developer handler", re-pointed at Lifecycle modules.) A
  # handler emits `{:dispatch, %Cmd{}}` effects; it never calls these
  # directly. SCOPED to `use Ezagent.Lifecycle` files only — Entity Kind
  # modules / LiveViews / mix tasks / adapters legitimately call dispatch
  # as the inbound/orchestration surface and are NOT Behavior handlers.
  # Strips pure prose mentions (backtick-quoted in moduledoc/comments).
  # ----------------------------------------------------------------------
  defp gate_no_engine_internals(files) do
    re =
      ~r/Ezagent\.Invocation\.dispatch\(|Ezagent\.EventLog\.append\(|Ezagent\.SnapshotStore\.(write|delete|save_now|upsert)\(/

    files
    |> Enum.filter(&lifecycle_module?/1)
    |> hits(re, &strip_prose/2)
    |> result(
      "gate_no_engine_internals (no Invocation.dispatch/SnapshotStore/EventLog.append inside a Lifecycle handler — emit effects)",
      "  ✓ no Lifecycle-handler direct engine-internals calls (emit effects instead)"
    )
  end

  # ----------------------------------------------------------------------
  # §11 NP-2 — layer-vocabulary lint (ezagent_core module names).
  # ----------------------------------------------------------------------
  defp gate_layer_vocab_lint do
    word_re = ~r/(#{Enum.join(@layer_vocab_words, "|")})/

    offenders =
      (Path.wildcard("apps/ezagent_core/lib/**/*.ex") ++
         Path.wildcard("apps/ezagent_actor/lib/**/*.ex"))
      |> Enum.reject(&test_support_file?/1)
      |> Enum.reject(&(&1 in @layer_vocab_allowlist))
      |> Enum.flat_map(fn path ->
        path
        |> module_names()
        |> Enum.filter(&Regex.match?(word_re, &1))
        |> Enum.map(fn mod -> "#{path}: module #{mod} names an upper-layer concept (NP-2)" end)
      end)

    case offenders do
      [] ->
        Mix.shell().info(
          "  ✓ NP-2 layer-vocabulary lint clean (ezagent_core names no upper-layer concept)"
        )

        :ok

      _ ->
        {:error, "NP-2 layer-vocabulary lint",
         Enum.join(offenders, "\n") <>
           "\n(fix: rename to a core-layer / capability name, or add to @layer_vocab_allowlist with justification)"}
    end
  end

  # ----------------------------------------------------------------------
  # §11 NP-3 — width lint. A `use Ezagent.Lifecycle` module whose last
  # name segment is a generic lifecycle/admin/manager word but which
  # declares <= 1 `action` is the over-promise smell (the original
  # `Lifecycle`-with-one-`:terminate` that became `Terminable`).
  # ----------------------------------------------------------------------
  defp gate_width_lint(files) do
    offenders =
      files
      |> Enum.filter(&lifecycle_module?/1)
      |> Enum.flat_map(fn path ->
        {:ok, content} = File.read(path)
        action_count = action_count(content)

        path
        |> module_names()
        |> Enum.filter(&generic_last_segment?/1)
        |> Enum.filter(fn _ -> action_count <= 1 end)
        |> Enum.map(fn mod ->
          "#{path}: module #{mod} has a generic name but declares #{action_count} action(s) (NP-3 over-promise)"
        end)
      end)

    case offenders do
      [] ->
        Mix.shell().info(
          "  ✓ NP-3 width lint clean (no generic-named <=1-action Lifecycle module)"
        )

        :ok

      _ ->
        {:error, "NP-3 width lint",
         Enum.join(offenders, "\n") <>
           "\n(fix: rename to a responsibility/capability name matching the action — see SPEC §11 Lifecycle->Terminable)"}
    end
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  # Grep `files` for `re`, returning "path:line:content" hit lines.
  # `keep_fun.(line, content_of_line)` lets a gate strip prose mentions.
  defp hits(files, re, keep_fun \\ fn _line, _content -> true end) do
    Enum.flat_map(files, fn path ->
      {:ok, content} = File.read(path)

      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(re, line) end)
      |> Enum.filter(fn {line, _n} -> keep_fun.(line, line) end)
      |> Enum.map(fn {line, n} -> "#{path}:#{n}:#{String.trim(line)}" end)
    end)
  end

  # Drop lines that are pure prose mentions (the symbol appears only
  # inside backticks, or the line is a comment/docstring line). Keeps
  # real code calls.
  defp strip_prose(_line, content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "#") -> false
      String.contains?(content, "`") and not String.contains?(content, "(") -> false
      true -> true
    end
  end

  defp result([], _failure_name, success_msg) do
    Mix.shell().info(success_msg)
    :ok
  end

  defp result(hit_lines, failure_name, _success_msg) do
    {:error, failure_name, Enum.join(hit_lines, "\n")}
  end

  # Extract the REAL top-level `defmodule Foo.Bar do` module names from a
  # source file. Anchored to column 0 (no leading whitespace) so the
  # INDENTED `defmodule` examples inside `@moduledoc`/`@doc` heredocs
  # (e.g. plugin.ex's `EzagentPluginCc.Application` sample) are NOT
  # mistaken for modules this file actually defines.
  defp module_names(path) do
    {:ok, content} = File.read(path)

    ~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m
    |> Regex.scan(content)
    |> Enum.map(fn [_, mod] -> mod end)
  end

  defp lifecycle_module?(path) do
    {:ok, content} = File.read(path)
    Regex.match?(~r/^\s*use\s+Ezagent\.Lifecycle\b/m, content)
  end

  # Count `action :name, ...` declarations in a Lifecycle module.
  defp action_count(content) do
    ~r/^\s*action\s+:[a-z_]+/m
    |> Regex.scan(content)
    |> length()
  end

  defp generic_last_segment?(module_name) do
    last = module_name |> String.split(".") |> List.last()
    last in @generic_name_tokens
  end
end
