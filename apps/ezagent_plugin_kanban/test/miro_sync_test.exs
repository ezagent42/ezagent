defmodule EzagentPluginKanban.MiroSyncTest do
  @moduledoc """
  V5 A1b chunk3 — MiroSync resolver-seam registration + teardown semantics.

  Network-free: the Miro creds/delete client is injected via start opts
  (`:read_creds` / `:delete_board`), so `terminate/2`'s board deletion is
  observed as a plain message. The sync CORE (`sync/1` → `Miro.get_nodes`)
  is NOT exercised here — that path is covered by the `:live_miro` e2e.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Runtime.Resolver
  alias EzagentPluginKanban.MiroSync

  @supervisor EzagentPluginKanban.MiroSyncSupervisor

  defp kanban_uri(tag),
    do:
      Ezagent.URI.new!("entity://test/agent/kanban-#{tag}-#{System.unique_integer([:positive])}")

  # bind a poller whose Miro client is faked: creds always resolve, and the
  # board deletion is reported to the test process instead of HTTP.
  defp bind_faked(uri, board_id) do
    test_pid = self()

    MiroSync.bind(uri, board_id,
      read_creds: fn -> {:ok, %{token: "tok-test", board_id: nil}} end,
      delete_board: fn token, board ->
        _ = send(test_pid, {:delete_board, token, board})
        :ok
      end
    )
  end

  describe "resolver-seam registration (V5 A1b)" do
    test "bind/3 self-registers under {kanban_uri, :ezagent_plugin_kanban, :miro_sync}" do
      uri = kanban_uri("bind")
      key = MiroSync.resolver_key(uri)

      assert Resolver.alive?(key) == false
      assert {:ok, _pid} = bind_faked(uri, "board-1")
      assert Resolver.alive?(key) == true

      # The internal board_id call resolves through the seam.
      assert {:ok, "board-1"} = Resolver.call(key, :board_id)

      assert :ok = Resolver.terminate_child(key, @supervisor)
    end

    test "sync_now/1 on an UNBOUND kanban maps the seam's :no_such_actor to :not_bound" do
      # The old not-bound detection was `catch :exit`-dependent; the seam
      # returns `:no_such_actor` for a missing key and the facade maps it
      # (same observable behavior).
      assert {:error, :not_bound} = MiroSync.sync_now(kanban_uri("unbound"))
    end
  end

  describe "teardown (audit peculiarity — delete_board in terminate/2 + restart: :transient)" do
    test "seam terminate_child deletes the board (terminate/2 ran) and does NOT respawn" do
      uri = kanban_uri("teardown")
      key = MiroSync.resolver_key(uri)

      assert {:ok, pid} = bind_faked(uri, "board-teardown")
      ref = Process.monitor(pid)

      assert :ok = Resolver.terminate_child(key, @supervisor)

      # terminate/2 ran on the supervisor's :shutdown (trap_exit): the Miro
      # board deletion fired with the injected creds' token + the bound board.
      assert_receive {:delete_board, "tok-test", "board-teardown"}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # `restart: :transient`: a graceful stop is NOT resurrected (the old
      # `:permanent` made every unbind non-durable). The seam entry dies with
      # the child (Registry async DOWN-cleanup — poll briefly).
      assert_eventually(fn -> Resolver.alive?(key) == false end)
      Process.sleep(100)
      assert Resolver.alive?(key) == false
      # …and no second poller lived to delete again.
      refute_received {:delete_board, _, _}
    end

    test "a plain GenServer.stop (any stop) also deletes the board" do
      uri = kanban_uri("stop")
      key = MiroSync.resolver_key(uri)

      assert {:ok, pid} = bind_faked(uri, "board-stop")

      assert :ok = GenServer.stop(pid)
      assert_receive {:delete_board, "tok-test", "board-stop"}, 1_000
      assert_eventually(fn -> Resolver.alive?(key) == false end)
    end
  end

  # Registry DOWN-cleanup is prompt but asynchronous — poll briefly.
  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition never became true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
