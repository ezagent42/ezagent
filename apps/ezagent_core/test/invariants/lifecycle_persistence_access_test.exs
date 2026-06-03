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
  a non-framework module:

    1. WRITES the snapshot table directly — `KindSnapshot.upsert(...)`.
       The only writers are the framework persistence modules. Domain
       state persists via the normal dispatch → `Kind.Server` commit path.
    2. Calls the sync write primitive `save_now/4` directly. Only
       `Kind.Server` / the async `Writer` / `Kind.Snapshot.commit` may.
    3. Reads the create-vs-activate marker `KindSnapshot.ever_created?(...)`
       directly. The single create/activate signal is
       `Ezagent.Lifecycle.fresh_create?/1` — go through it so the
       decision has exactly one definition and cannot drift.

  As of 2026-06-03 the codebase is ALREADY clean on all three axes — this
  test locks that in. A new violation means: route the call through the
  Lifecycle / framework function, or (if genuinely a framework-internal
  site) add it to the rule's allowlist with a one-line justification.

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
      regex: ~r/(?<![\.\w])KindSnapshot\.upsert\s*\(/,
      allowlist: [
        # The Lifecycle/RBK persistence module — the canonical write path.
        "apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
        # The framework-internal snapshot store (versioned write + reads).
        "apps/ezagent_core/lib/ezagent/snapshot_store.ex"
      ],
      guidance:
        "Domain/Behavior/plugin state persists via the normal dispatch → " <>
          "Kind.Server commit path; do not write `kind_snapshots` directly."
    },
    %{
      name: "direct sync-write primitive (save_now/4)",
      regex: ~r/(?<![\.\w])save_now\s*\(/,
      allowlist: [
        # Defines save_now + calls it from commit/4 (the :on_change policy gate).
        "apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
        # Kind.Server: initial persist + terminate + periodic.
        "apps/ezagent_core/lib/ezagent/kind/server.ex",
        # The async snapshot Writer flush path.
        "apps/ezagent_core/lib/ezagent/snapshot/writer.ex"
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
        "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex",
        # The ONE Lifecycle owner of the create/activate decision (wraps it
        # in marker_lookup + exposes `fresh_create?/1`).
        "apps/ezagent_core/lib/ezagent/lifecycle.ex"
      ],
      guidance:
        "The create-vs-activate signal is `Ezagent.Lifecycle.fresh_create?/1` " <>
          "— use it; never re-derive freshness from the marker / a save return."
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
