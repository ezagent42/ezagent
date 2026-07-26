defmodule EzagentDomainInstanceMessage.Integration.SessionKindBaseThreadingTest do
  @moduledoc """
  P5-0b / P5-1b — every session-spawn entry point threads an explicit
  `:behaviors` set, so a freshly-spawned session persists a NON-nil `:kind_base`.
  Post-P5-1b `Session.behaviors/0` is the union, so the "session" SpawnRegistry
  route threads the CHAT SUBSET (`Session.chat_behaviors/0`) — that is what the
  persisted `:kind_base` must equal (not the union, not the legacy sentinel nil).

  Drives the PRODUCTION path: `SpawnRegistry.spawn(session://...)` → the
  registered "session" route (`application.ex`) → `Kind.spawn(Session,
  %{behaviors: Session.chat_behaviors()})`. Reads the live `:kind_base` slice
  back and asserts it captured the chat subset.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Entity.Session

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Read a slice with a bounded retry — under the shared-suite concurrency the
  # Kind may not be registered in `KindRegistry` the instant `spawn` returns
  # (readiness/announce race; see DataCase moduledoc). Retry briefly.
  defp get_slice_eventually(uri, slice_key, attempts \\ 50)
  defp get_slice_eventually(_uri, _slice_key, 0), do: {:error, :never_ready}

  defp get_slice_eventually(uri, slice_key, attempts) do
    case Ezagent.Kind.read(uri, slice_key, spawn: :never) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        Process.sleep(20)
        get_slice_eventually(uri, slice_key, attempts - 1)
    end
  end

  test "SpawnRegistry session route persists a non-nil :kind_base == Session.chat_behaviors()" do
    session_uri = Ezagent.URI.session(:system, :default, unique("kb-thread"))

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(session_uri)

    {:ok, slice} = get_slice_eventually(session_uri, :kind_base)

    captured = KindBase.behaviors_in_slice(slice)

    refute is_nil(captured),
           "session :kind_base must be a non-nil explicit set after P5-0b threading"

    assert captured == Session.chat_behaviors()
  end

  test "the spawned session's effective_set does NOT raise the scoped guard (explicit set present)" do
    session_uri = Ezagent.URI.session(:system, :default, unique("kb-guard"))

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(session_uri)

    # The Kind boots + stays alive through reload-derived effective_set on every
    # dispatch; if :kind_base were nil the scoped guard would have crashed it.
    assert {:ok, _} = get_slice_eventually(session_uri, :session)
  end
end
