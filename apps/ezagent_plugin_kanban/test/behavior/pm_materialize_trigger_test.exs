defmodule Ezagent.Behavior.Kanban.PmMaterializeTriggerTest do
  @moduledoc """
  Phase 3 ③ T7c/T7d — the kanban-flow TRIGGER for the per-session role-agent
  materialize. Binding a board to a session (`bind_session`) is the kanban-flow
  session ESTABLISHMENT point; it fires BOTH:

    * `PmCoordinatorSeed.materialize/3` for pm-coordinator (T7c), and
    * `SessionAgentMaterialize.materialize_by_role("dev-together", …)` for
      dev-together (T7d — a FOREIGN plugin reached generically by role name).

  Both are best-effort + non-blocking. This pins the WIRING (the `:triggered`
  telemetry fires on a successful bind, the bind itself stays `:ok`). The actual
  `cc` spawn is skipped in `:test` (no live `claude`; the spawn MECHANISM is proven
  by `SessionAgentMaterializeTest`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Kanban.Connectors

  @triggered [:ezagent, :kanban, :pm_coordinator_seed, :materialize, :triggered]
  @dev_triggered [:ezagent, :kanban, :dev_together, :materialize, :triggered]
  @relay_back_triggered [:ezagent, :kanban, :relay_back, :materialize, :triggered]

  defp uniq, do: System.unique_integer([:positive])

  test "bind_session fires the per-session pm materialize trigger + stays :ok" do
    board_uri = Ezagent.URI.agent("team-alpha", "kanban-board-#{uniq()}")
    session_uri = "session://default/team-alpha/board-flow-#{uniq()}"
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/alice-#{uniq()}")

    ref = :telemetry_test.attach_event_handlers(self(), [@triggered])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, %{session_uri: ^session_uri}, []} =
             Connectors.bind_session(%{session_uri: session_uri}, %{
               self_uri: board_uri,
               caller: owner_uri
             })

    assert_received {@triggered, ^ref, %{count: 1}, %{session_uri: ^session_uri}}
  end

  test "bind_session ALSO fires the per-session dev-together materialize trigger (T7d)" do
    board_uri = Ezagent.URI.agent("team-alpha", "kanban-board-#{uniq()}")
    session_uri = "session://default/team-alpha/board-flow-#{uniq()}"
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/alice-#{uniq()}")

    ref = :telemetry_test.attach_event_handlers(self(), [@dev_triggered])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, %{session_uri: ^session_uri}, []} =
             Connectors.bind_session(%{session_uri: session_uri}, %{
               self_uri: board_uri,
               caller: owner_uri
             })

    assert_received {@dev_triggered, ^ref, %{count: 1}, %{session_uri: ^session_uri}}
  end

  test "bind_session ALSO fires the dev→pm relay-BACK routing trigger (T12) + stays :ok" do
    board_uri = Ezagent.URI.agent("team-alpha", "kanban-board-#{uniq()}")
    session_uri = "session://default/team-alpha/board-flow-#{uniq()}"
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/alice-#{uniq()}")

    ref = :telemetry_test.attach_event_handlers(self(), [@relay_back_triggered])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, %{session_uri: ^session_uri}, []} =
             Connectors.bind_session(%{session_uri: session_uri}, %{
               self_uri: board_uri,
               caller: owner_uri
             })

    assert_received {@relay_back_triggered, ^ref, %{count: 1}, %{session_uri: ^session_uri}}
  end

  test "bind_session with no resolvable owner (no caller) still binds, no trigger" do
    board_uri = Ezagent.URI.agent("team-alpha", "kanban-board-#{uniq()}")
    session_uri = "session://default/team-alpha/board-flow-#{uniq()}"

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        @triggered,
        @dev_triggered,
        @relay_back_triggered
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, %{session_uri: ^session_uri}, []} =
             Connectors.bind_session(%{session_uri: session_uri}, %{self_uri: board_uri})

    refute_received {@triggered, ^ref, _, _}
    refute_received {@dev_triggered, ^ref, _, _}
    refute_received {@relay_back_triggered, ^ref, _, _}
  end
end
