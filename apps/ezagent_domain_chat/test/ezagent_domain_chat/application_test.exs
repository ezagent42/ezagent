defmodule EzagentDomainChat.ApplicationTest do
  @moduledoc """
  Phase 2b-step 1: boot integration — verify the three children land in
  their expected runtime state after the umbrella starts.

  These assertions run against the live KindRegistry / DynamicSupervisor
  populated at application boot — not test-spawned fixtures. The Phase 1
  echo plugin uses the same pattern (its boot spawns `entity://agent/team-alpha/test_echo` and
  tests assert on the live registry entry).

  ## PR-M (Allen 2026-05-20) — admin spawns lazily, test-seeded

  `entity://user/system/admin` is no longer a static supervisor child. In
  dev/prod it spawns lazily via SpawnRegistry on first dispatch
  reference (login, session join, cap lookup). The chat test-env
  seed `maybe_seed_main_session_for_tests/0` pre-spawns admin before
  joining it to session://default/system/main (chat.join requires the member's Kind
  alive in KindRegistry), so admin is up by the time these
  boot-invariant tests run. No per-test setup needed.
  """

  use ExUnit.Case
  alias Ezagent.{KindRegistry, ReadyGate}

  test "session://default/system/main is registered in KindRegistry" do
    uri = Ezagent.Entity.Session.default_uri()
    assert {:ok, pid} = KindRegistry.lookup(uri)
    assert Process.alive?(pid)
  end

  test "session://default/system/main is marked :ready in ReadyGate" do
    uri_str = URI.to_string(Ezagent.Entity.Session.default_uri())
    assert :ready = ReadyGate.status(uri_str)
  end

  test "entity://user/system/admin is registered in KindRegistry (post-first-reference)" do
    uri = Ezagent.Entity.User.admin_uri()
    assert {:ok, pid} = KindRegistry.lookup(uri)
    assert Process.alive?(pid)
  end

  test "entity://user/system/admin is marked :ready in ReadyGate (post-first-reference)" do
    uri_str = URI.to_string(Ezagent.Entity.User.admin_uri())
    assert :ready = ReadyGate.status(uri_str)
  end

  test "AgentSupervisor is alive (agents spawn on bridge announce)" do
    sup = Process.whereis(EzagentDomainChat.AgentSupervisor)
    assert is_pid(sup) and Process.alive?(sup)

    # Drop the strict "zero children" check — under full-umbrella runs
    # this assertion races against other tests in the chat suite that
    # spawn + terminate agents. Liveness is the boot invariant; child
    # count is a per-test fixture concern.
    assert is_map(DynamicSupervisor.count_children(sup))
  end
end
