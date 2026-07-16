defmodule Ezagent.Kind.TerminateTest do
  @moduledoc """
  codex round-10 HIGH-2 — `Ezagent.Kind.terminate/1` is the tier-clean
  Kind-process teardown primitive a plugin Template Class uses to undo
  its OWN partial spawn (it freshly STARTED a Kind, then a later step
  of the same instantiate failed). A Tier-3 plugin cannot name a Tier-2
  supervisor constant, so `terminate/1` resolves the owning
  `DynamicSupervisor` itself by asking the live `Kind.Server` for its
  Kind module.

  These tests pin the contract: a spawned Kind is gone after
  `terminate/1`; the call is idempotent (an absent URI returns `:ok`);
  and it stays best-effort under a garbage URI.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Test.TestKind

  defp uniq, do: System.unique_integer([:positive])

  defp test_uri,
    do: Ezagent.URI.new!("entity://team-alpha/agent/test_kind-terminate-#{uniq()}")

  defp wait_gone(uri, attempts \\ 200)
  defp wait_gone(_uri, 0), do: :still_there

  defp wait_gone(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> Process.sleep(5) && wait_gone(uri, attempts - 1)
    end
  end

  test "terminate/1 brings down a live Kind process and frees its URI" do
    uri = test_uri()

    {:ok, pid} = Ezagent.Kind.spawn(TestKind, %{uri: uri})
    assert Process.alive?(pid)
    assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri)

    assert :ok = Ezagent.Kind.terminate(uri)

    # The DynamicSupervisor child is PERMANENTLY removed — a bare
    # Process.exit on a :permanent child would be restarted; this
    # asserts the supervisor-routed terminate actually removed it.
    assert :ok = wait_gone(uri),
           "the Kind process must be gone after Ezagent.Kind.terminate/1 — " <>
             "and must NOT be restarted by its DynamicSupervisor"

    refute Process.alive?(pid)
  end

  test "terminate/1 is idempotent — an absent / already-terminated URI returns :ok" do
    uri = test_uri()

    # Never spawned — terminate must be a clean no-op.
    assert :ok = Ezagent.Kind.terminate(uri)

    # Spawn, terminate, then terminate AGAIN — the second call is a
    # no-op (the partial-spawn caller may retry teardown).
    {:ok, _pid} = Ezagent.Kind.spawn(TestKind, %{uri: uri})
    assert :ok = Ezagent.Kind.terminate(uri)
    assert :ok = wait_gone(uri)
    assert :ok = Ezagent.Kind.terminate(uri)
  end

  test "terminate/1 is best-effort — a URI with no live Kind never raises" do
    # A well-formed URI that was never spawned: no KindRegistry entry,
    # the `with` falls through to `:ok`. A teardown step on a failure
    # exit must never mask the original error with a raise.
    assert :ok =
             Ezagent.Kind.terminate(
               Ezagent.URI.new!("session://team-alpha/default/never-#{uniq()}")
             )
  end
end
