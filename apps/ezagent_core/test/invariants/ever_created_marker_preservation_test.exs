defmodule Ezagent.Invariants.EverCreatedMarkerPreservationTest do
  @moduledoc """
  G-3/v4-H2b empty-tolerance enumerator gate.

  A non-delete snapshot clear must preserve a Lifecycle principal's
  `ever_created` marker. Otherwise standalone revocation followed by lazy spawn
  is misclassified as a genuine create and can mint a fresh self-license.
  Genuine Lifecycle destroy remains the only production full-row delete; agent
  retirement is safe because it reaches that destroy path for a snapshot-only
  Agent rather than leaving a separately-provisioned identity row behind.
  """

  use ExUnit.Case, async: true

  @apps_root Path.expand("../../../..", __DIR__)

  test "no non-delete production site drops the ever-created marker" do
    violations =
      production_files()
      |> Enum.flat_map(&full_row_delete_violations/1)

    assert violations == [],
           """
           ever_created marker-preservation violations (empty tolerance):
           #{Enum.map_join(violations, "\n", &"  - #{&1}")}

           Route non-delete clearing through
           KindSnapshot.clear_state_preserving_marker/1. Only
           Lifecycle.do_destroy/2 may perform a full-row delete.
           """
  end

  test "the four grounded reachability sites use a marker-safe mechanism" do
    snapshot_store = source("apps/ezagent_core/lib/ezagent/snapshot_store.ex")
    clear_task = source("apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.clear.ex")
    backfill = source("apps/ezagent_core/lib/ezagent/kind/kind_base_backfill.ex")
    teardown = source("apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex")
    retirement = source("apps/ezagent_domain_agent/lib/ezagent/agent/retirement.ex")

    assert snapshot_store =~ "KindSnapshot.clear_state_preserving_marker("
    assert clear_task =~ "KindSnapshot.clear_state_preserving_marker("
    assert backfill =~ "KindSnapshot.clear_state_preserving_marker("
    assert teardown =~ "Ezagent.Domain.Agent.retire_spawned("
    assert retirement =~ ":sandbox, :destroy"
    refute retirement =~ "KindSnapshot.delete("
  end

  defp full_row_delete_violations(relative_path) do
    source = source(relative_path)

    if source =~ "KindSnapshot.delete(" or source =~ "Ezagent.Ecto.KindSnapshot.delete(" do
      cond do
        relative_path == "apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex" -> []
        relative_path == "apps/ezagent_core/lib/ezagent/lifecycle.ex" -> []
        true -> [relative_path]
      end
    else
      []
    end
  end

  defp production_files do
    Path.wildcard(Path.join(@apps_root, "apps/*/lib/**/*.ex"))
    |> Enum.map(&Path.relative_to(&1, @apps_root))
    |> Enum.sort()
  end

  defp source(relative_path), do: File.read!(Path.join(@apps_root, relative_path))
end
