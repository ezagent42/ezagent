defmodule Ezagent.UriQuery.ScanHomePathReconcileTest do
  @moduledoc """
  Reconciliation gate (Resource-unification P0.5, decision **b**).

  TWO scanners observe raw `Ezagent.Home.path` calls and MUST NOT drift:

    * `mix ezagent.arch.scan` `raw_home_path_outside_core` — the **count
      ratchet** for the #25 fitness goal ("core should own `Home`"). It text-greps
      `Home.path(` across `apps/**/lib/**/*.ex` and counts every hit OUTSIDE
      `apps/ezagent_core/`, capped in `arch_baseline_manifest.exs`.

    * `mix ezagent.uri_query.scan` `home_path_in_runtime_code` — the **hard-fail-
      NEW enforcement** with the boot/operator/OS-handle exemption set
      (`HomePathExceptions`) + the burn-down `HomePathBaseline`.

  They have different jobs (a count ratchet vs. a precise hard-fail-new gate) and
  different surfaces (text-grep `Home.path(` outside-core vs. AST `path|profile_dir|
  home` over ALL apps incl. core). Sharing one detector (option a) would change
  arch.scan's count semantics and risk the #25 ratchet, so P0.5 keeps them
  separate but **provably consistent**:

  > Every `Home.path(` call that arch.scan counts in `raw_home_path_outside_core`
  > MUST be known to P0.5 — present in EITHER `HomePathBaseline` OR
  > `HomePathExceptions`.

  That makes the two lists reconcile by construction: neither scanner can grow a
  raw `Home.path` call the other doesn't know about. A new outside-core call
  raises arch.scan's count (ratchet) AND, being neither baselined nor exempt,
  fails `home_path_in_runtime_code` (hard-fail-new) — and this test fails if
  someone adds it to one list but not the other's awareness.
  """
  use ExUnit.Case, async: true

  alias Ezagent.UriQuery.Scan.HomePathBaseline
  alias Ezagent.UriQuery.Scan.HomePathExceptions

  @repo_root Path.expand("../../../../..", __DIR__)

  test "every arch.scan raw_home_path_outside_core hit is known to P0.5 (baseline ∪ exceptions)" do
    known = known_anchor_set()

    unknown =
      arch_scan_outside_core_hits()
      |> Enum.reject(fn {path, line} -> MapSet.member?(known, {path, line}) end)

    assert unknown == [],
           """
           arch.scan counts these outside-core Home.path() calls in \
           raw_home_path_outside_core, but P0.5 (uri_query.scan) does not know them \
           (not in HomePathBaseline nor HomePathExceptions). The two scanners have \
           drifted — add each anchor to the correct P0.5 list:

           #{Enum.map_join(unknown, "\n", fn {p, l} -> "  #{p}:#{l}" end)}
           """
  end

  test "P0.5 exception anchors do not silently shadow a count the ratchet should see" do
    # Sanity: no apps/ exception anchor sits OUTSIDE core unless arch.scan also
    # sees it (otherwise an exemption could hide a call the #25 ratchet must
    # count). Outside-core apps/ exceptions must appear in arch.scan's hit set.
    arch_set = MapSet.new(arch_scan_outside_core_hits())

    orphans =
      HomePathExceptions.app_anchors()
      |> Enum.filter(fn {path, _fun, _line, _r} ->
        String.starts_with?(path, "apps/") and not String.starts_with?(path, "apps/ezagent_core/")
      end)
      |> Enum.reject(fn {path, _fun, line, _r} -> MapSet.member?(arch_set, {path, line}) end)

    assert orphans == [],
           "outside-core exception anchors not visible to arch.scan: #{inspect(orphans)}"
  end

  # The P0.5 anchor set: every {path, line} the uri_query.scan gate knows about.
  defp known_anchor_set do
    baseline = Enum.map(HomePathBaseline.all(), fn {path, line, _call} -> {path, line} end)

    exceptions =
      Enum.map(HomePathExceptions.all(), fn {path, _fun, line, _r} -> {path, line} end)

    MapSet.new(baseline ++ exceptions)
  end

  # Reproduce arch.scan's raw_home_path_outside_core hit set: text-grep
  # `Home.path(` over apps/*/lib/**/*.ex (excluding /test/ and `# arch-allow:`),
  # keep hits OUTSIDE apps/ezagent_core/. Returns [{rel_path, line}].
  defp arch_scan_outside_core_hits do
    @repo_root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.reject(&String.starts_with?(&1, "apps/ezagent_core/"))
    |> Enum.flat_map(fn rel ->
      @repo_root
      |> Path.join(rel)
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        if String.contains?(line, "Home.path(") and not String.contains?(line, "# arch-allow:") do
          [{rel, line_no}]
        else
          []
        end
      end)
    end)
  end
end
