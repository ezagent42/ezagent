defmodule EzagentCore.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EzagentCore.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias EzagentCore.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import EzagentCore.DataCase
    end
  end

  setup tags do
    EzagentCore.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  ## Why the extra `on_exit` (remediation P6 — sandbox-owner-exit drain)

  Integration tests spawn `Ezagent.Kind.Server` GenServers (via
  `Ezagent.Kind.spawn/2` / dispatch) under GLOBAL `DynamicSupervisor`s.
  In shared sandbox mode (`shared: not async`) those Kinds inherit the
  test's checked-out connection from the sandbox owner. A Kind runs
  Repo queries OUTSIDE the test process — in `handle_continue`
  (`activate/2` → DB projection reads), `handle_info` snapshot writes,
  etc. — so it can still be mid-query when the test body returns.

  `start_owner!` registers `on_exit(stop_owner)` for us. If that were
  the only teardown, the owner's connection would be reclaimed while a
  Kind is still using it, producing the deterministic
  `DBConnection.ConnectionError` "owner #PID exited / Client #PID is
  still using a connection from owner" error. In the
  `apps/ezagent_domain_chat` suite (`--max-cases 1 --seed 0`) this
  surfaced as ~40-50 such error log occurrences per run, crashing the
  offending Kinds mid-teardown. (The chat suite's *test* failures are a
  separate, pre-existing set of assertion / `:not_ready` bugs out of P6
  scope — the DBConnection errors were async log noise from torn-down
  Kinds, not the cause of those assertions.)

  Fix: register a SECOND `on_exit` that DRAINS every live Kind *before*
  the owner is stopped. ExUnit runs `on_exit` callbacks LIFO, and this
  one is registered after `start_owner!`'s, so it runs first. The drain
  issues a benign synchronous `GenServer.call(pid, :ezagent_kind_module)`
  to each Kind: a `call` only returns once the GenServer has processed
  every message ahead of it in its mailbox — including any in-flight
  `handle_continue` / `handle_info` that is mid-query. So when the call
  returns, that Kind has no DB work outstanding on the owner's
  connection, and `stop_owner` can safely reclaim it.

  We deliberately DRAIN rather than TERMINATE: this suite reuses fixed
  Kind URIs across tests and relies on `SpawnRegistry.spawn/1` being
  idempotent for an already-live Kind. Terminating the Kinds would
  expose latent per-test activation races (`:not_ready`) that Kind
  persistence currently masks — i.e. it would trade the DBConnection
  flakiness for a *different* flakiness class. Draining keeps the blast
  radius to exactly the DBConnection class.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    on_exit(&drain_live_kinds/0)
  end

  # Bounded number of drain passes. One pass flushes each Kind's mailbox
  # AS OF the moment of the call; but a late PubSub broadcast (presence
  # diff, slice-change fan-out) from a still-running process can land a
  # fresh `handle_info` AFTER that pass — which then writes a snapshot
  # under the about-to-be-stopped owner. Re-passing while any Kind still
  # has queued messages drains those stragglers too. Bounded so a
  # genuinely busy-looping Kind can't hang teardown; the rare message
  # that arrives after the final pass is best-effort (it logs but does
  # not fail any assertion — see moduledoc).
  @drain_passes 4

  # Flush in-flight DB work out of every live Kind so no query outlives
  # the sandbox owner's connection. A synchronous `GenServer.call`
  # returns only after the Kind has drained its mailbox up to that call,
  # so any mid-flight `handle_continue`/`handle_info` that is mid-query
  # completes against the still-valid connection. Best-effort: a Kind
  # that exits or times out mid-drain is already not holding the
  # connection.
  defp drain_live_kinds, do: drain_live_kinds(@drain_passes)

  defp drain_live_kinds(0), do: :ok

  defp drain_live_kinds(passes_left) do
    kinds = registered_kinds()

    Enum.each(kinds, fn {_uri, pid} ->
      try do
        GenServer.call(pid, :ezagent_kind_module, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    # If any Kind still has queued messages, another late `handle_info`
    # is pending — make one more pass. Otherwise we're quiescent.
    if Enum.any?(kinds, fn {_uri, pid} ->
         match?({:message_queue_len, n} when n > 0, Process.info(pid, :message_queue_len))
       end) do
      drain_live_kinds(passes_left - 1)
    else
      :ok
    end
  end

  defp registered_kinds do
    Ezagent.KindRegistry.list_all()
  rescue
    # KindRegistry not started (pure-unit suites) — nothing to drain.
    _ -> []
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
