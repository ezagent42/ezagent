defmodule Ezagent.Invariants.LifecyclePersistenceAccessTest do
  @moduledoc """
  Persistence-access discipline invariant (Allen 2026-06-03 — "基于
  lifecycle，不要基于特定的函数；用 lifecycle 的宏或者定义好的函数").

  The principle: snapshot persistence and the create-vs-activate decision
  are **framework / Lifecycle concerns**. Behavior, plugin, and domain
  code must go through the Lifecycle macro + the framework's defined
  functions — never reach for the low-level persistence primitives
  directly. This is what stops a second, drifting persistence path from
  re-appearing (e.g. the reverted `save_initial/4` deviation that keyed
  the freshness signal off a save return instead of `Lifecycle.fresh_create?/1`).

  This test scans every production (`apps/*/lib`) source file and fails if
  a non-framework module reaches a low-level persistence / Lifecycle-marker
  primitive directly, across the FULL Lifecycle surface — create AND
  destroy AND the markers:

    1. WRITES the snapshot table directly — `KindSnapshot.upsert(...)`.
       The only writers are the framework persistence modules. Domain
       state persists via the normal dispatch → `Kind.Server` commit path.
    2. Calls the sync write primitive `save_now/4` directly. Only
       `Kind.Server` / the async `Writer` / `Kind.Snapshot.commit` may.
    3. Reads the create-vs-activate marker `KindSnapshot.ever_created?(...)`
       directly. The single create/activate signal is
       `Ezagent.Lifecycle.fresh_create?/1`.
    4. Writes the create marker `KindSnapshot.mark_ever_created(...)`
       directly. It is written atomically by the initial persist under
       the Lifecycle/Kind.Server path.
    5. DELETES a snapshot / tears a Kind down via `KindSnapshot.delete(...)`
       directly. Kind destroy goes through `Ezagent.Lifecycle.destroy/2`
       (hooks → snapshot+marker clear → terminate); domain code must not
       hand-roll `terminate + KindSnapshot.delete`.

  As of 2026-06-03 the codebase is clean on all five axes (the chat
  rollback/dissolve/compensate paths were migrated from a hand-rolled
  `terminate + KindSnapshot.delete` onto `Lifecycle.destroy/2` as part of
  this change) — this test locks that in. A new violation means: route the
  call through the Lifecycle / framework function named in the guidance, or
  (if a genuine framework-internal / operator-ops site) add it to the
  rule's allowlist with a one-line justification.

  Scans production code only (`apps/*/lib`); tests legitimately seed
  snapshot rows via the store helpers. Mirrors
  `agent_create_single_path_test.exs`.
  """

  use ExUnit.Case, async: true

  # Each rule: a human name, the forbidden-call regex, the framework
  # modules allowed to make that call, and the guidance shown on failure.
  @rules [
    %{
      name: "direct snapshot-table WRITE (KindSnapshot.upsert)",
      # Match both the aliased `KindSnapshot.upsert(` and the fully-qualified
      # `Ezagent.Ecto.KindSnapshot.upsert(` (codex: a bare `KindSnapshot`
      # pattern + `(?<![\.\w])` lookbehind misses the qualified form).
      regex: ~r/(?<![\.\w])(?:KindSnapshot|Ezagent\.Ecto\.KindSnapshot)\.upsert\s*\(/,
      allowlist: [
        # The Lifecycle/RBK persistence module — the canonical write path.
        "apps/ezagent_actor/lib/ezagent/kind/snapshot.ex",
        # The framework-internal snapshot store (versioned write + reads).
        "apps/ezagent_actor/lib/ezagent/snapshot_store.ex",
        # P5-0 migration (TEST/sandbox only): rewrites the :kind_base slice of
        # EXISTING session rows in place. It intentionally uses a direct
        # `KindSnapshot.upsert/5` rather than `Snapshot.save_now/3` because it
        # lives in ezagent_actor, which has NO dependency on the domain-owned
        # session Kind modules `save_now/3` would need to resolve. Framework-
        # internal one-shot migration, not a domain/Behavior write path.
        "apps/ezagent_actor/lib/ezagent/kind/kind_base_backfill.ex",
        # chat→session one-shot MIGRATION (TEST/sandbox only): rewrites the
        # top-level `:chat`→`:session` slice key on EXISTING session rows in
        # place. Same direct-`upsert` rationale as kind_base_backfill (core, no
        # dependency on the domain session Kind modules `save_now/3` resolves).
        "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
        # chat→session one-shot grant MIGRATION (TEST/sandbox only): rewrites
        # persisted `Behavior.Chat`→`Behavior.Session` caps in the `:identity`
        # slice of EXISTING snapshot rows. Framework-internal row-level rewrite,
        # not a domain/Behavior write path.
        "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
        # curl-as-flavor one-shot MIGRATION (TEST/sandbox only, PR-6+7): rewrites
        # EXISTING `curl_agent` rows onto the unified Agent Kind (`kind_type`,
        # `flavor` slice, curl `:kind_base`, `:curl_agent → :agent` cap axis).
        # Same direct-`upsert` rationale as the other one-shot migrations: a
        # framework-internal row-level rewrite that runs Repo-only (NOT through
        # the domain dispatch/commit path, which would cold-load the very rows it
        # repairs against the deleted standalone curl Kind).
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex"
      ],
      guidance:
        "Domain/Behavior/plugin state persists via the normal dispatch → " <>
          "Kind.Server commit path; do not write `kind_snapshots` directly."
    },
    %{
      name: "direct sync-write primitive (save_now/4)",
      # `\b` so this catches BOTH the bare `save_now(` (inside Kind.Snapshot)
      # and the fully-qualified `Ezagent.Kind.Snapshot.save_now(` form
      # (codex P3: a `(?<![\.\w])` lookbehind would miss the qualified call).
      regex: ~r/\bsave_now\s*\(/,
      allowlist: [
        # Defines save_now + calls it from commit/4 (the :on_change policy gate).
        "apps/ezagent_actor/lib/ezagent/kind/snapshot.ex",
        # Kind.Server: initial persist + terminate + periodic.
        "apps/ezagent_actor/lib/ezagent/kind/server.ex",
        # The async snapshot Writer flush path.
        "apps/ezagent_actor/lib/ezagent/snapshot/writer.ex"
      ],
      guidance:
        "Persistence is policy-gated by `Kind.Snapshot.commit/4` and driven " <>
          "by `Kind.Server` / the `Writer`. Don't call `save_now/4` directly."
    },
    %{
      name: "direct create-vs-activate marker READ (KindSnapshot.ever_created?)",
      regex: ~r/(?<![\.\w])(?:KindSnapshot|Ezagent\.Ecto\.KindSnapshot)\.ever_created\?\s*\(/,
      allowlist: [
        # Defines ever_created? + mark.
        "apps/ezagent_actor/lib/ezagent/ecto/kind_snapshot.ex",
        # The ONE Lifecycle owner of the create/activate decision (wraps it
        # in marker_lookup + exposes `fresh_create?/1`).
        "apps/ezagent_actor/lib/ezagent/lifecycle.ex"
      ],
      guidance:
        "The create-vs-activate signal is `Ezagent.Lifecycle.fresh_create?/1` " <>
          "— use it; never re-derive freshness from the marker / a save return."
    },
    %{
      name: "direct create marker WRITE (KindSnapshot.mark_ever_created)",
      regex: ~r/(?<![\.\w])(?:KindSnapshot|Ezagent\.Ecto\.KindSnapshot)\.mark_ever_created\s*\(/,
      allowlist: [
        # Defines the marker write.
        "apps/ezagent_actor/lib/ezagent/ecto/kind_snapshot.ex",
        # The Lifecycle owner of the create marker.
        "apps/ezagent_actor/lib/ezagent/lifecycle.ex"
      ],
      guidance:
        "The ever-created marker is written atomically by the initial persist " <>
          "(`save_now`/`upsert` with `mark_ever_created: true`) under the " <>
          "Lifecycle/Kind.Server path — never mark it directly."
    },
    %{
      name: "direct snapshot DELETE / destroy teardown (KindSnapshot.delete)",
      regex: ~r/(?<![\.\w])(?:KindSnapshot|Ezagent\.Ecto\.KindSnapshot)\.delete\s*\(/,
      allowlist: [
        # Defines the row delete.
        "apps/ezagent_actor/lib/ezagent/ecto/kind_snapshot.ex",
        # `Lifecycle.destroy/2` — THE Kind teardown primitive (hooks →
        # snapshot+marker clear → terminate). All domain destroy goes here.
        "apps/ezagent_actor/lib/ezagent/lifecycle.ex",
        # Framework snapshot store wraps the row delete.
        "apps/ezagent_actor/lib/ezagent/snapshot_store.ex",
        # Operator escape hatches (NOT domain lifecycle): bulk ops clear +
        # admin single-row maintenance. Explicitly low-level ops tools.
        "apps/ezagent_actor/lib/mix/tasks/ezagent.snapshot.clear.ex",
        # P5-0 one-shot MIGRATION task (NOT a lifecycle handler): the
        # `:kind_base` backfill CLEARS an un-migratable legacy JSON-column
        # session row (Allen 2026-06-12) so the go/no-go gate can reach zero. It
        # already writes directly via the upsert-rule allowlist above; the
        # delete is the same row-level migration authority, not a domain teardown.
        "apps/ezagent_actor/lib/ezagent/kind/kind_base_backfill.ex"
      ],
      guidance:
        "Destroy a Kind via `Ezagent.Lifecycle.destroy/2` (runs developer " <>
          "destroy hooks, clears the snapshot row + marker, terminates) — " <>
          "domain code must NOT hand-roll `terminate + KindSnapshot.delete`."
    }
  ]

  test "snapshot persistence + create/activate go through the framework/Lifecycle only" do
    apps_root = Path.expand("../../../..", __DIR__)
    production_files = list_production_files(apps_root)

    violations =
      Enum.flat_map(@rules, fn rule ->
        production_files
        |> Enum.filter(fn rel_path ->
          rel_path not in rule.allowlist and
            rule.regex
            |> Regex.match?(strip_comments(Path.join(apps_root, rel_path)))
        end)
        |> Enum.map(fn rel_path -> {rule, rel_path} end)
      end)

    assert violations == [],
           """
           Persistence-access discipline violated — non-framework code reaches a
           low-level persistence/marker primitive directly instead of going through
           the Lifecycle / framework function:

           #{format_violations(violations)}

           Principle (Allen 2026-06-03): base persistence + create/activate on the
           Lifecycle macro and defined functions, not on specific low-level functions.
           Either route the call through the framework/Lifecycle function named in the
           guidance, or — if this is genuinely a framework-internal site — add the file
           to that rule's `@allowlist` in this test with a one-line justification.
           """
  end

  defp format_violations(violations) do
    violations
    |> Enum.group_by(fn {rule, _} -> rule.name end, fn {rule, rel} -> {rel, rule.guidance} end)
    |> Enum.map_join("\n\n", fn {rule_name, entries} ->
      {_rel, guidance} = hd(entries)
      files = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      "  • #{rule_name}\n    → #{guidance}\n" <>
        Enum.map_join(files, "\n", fn f -> "      #{f}" end)
    end)
  end

  # Strip single-line `#` comments so moduledoc / @doc prose describing a
  # primitive (e.g. "see `KindSnapshot.upsert`") doesn't count as a call.
  defp strip_comments(full_path) do
    full_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp list_production_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      full_lib = Path.join([apps_root, "apps", app, "lib"])

      if File.dir?(full_lib) do
        full_lib
        |> list_ex_files()
        |> Enum.map(&Path.relative_to(&1, apps_root))
      else
        []
      end
    end)
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end
end
