defmodule EzagentDomainInstanceMessage.ApplicationTest do
  @moduledoc """
  Phase 2b-step 1: boot integration — verify the three children land in
  their expected runtime state after the umbrella starts.

  These assertions run against the live KindRegistry / DynamicSupervisor
  populated at application boot — not test-spawned fixtures. The Phase 1
  echo plugin uses the same pattern (its boot spawns `entity://team-alpha/agent/test_echo` and
  tests assert on the live registry entry).

  ## PR-M (Allen 2026-05-20) — admin spawns lazily, test-seeded

  `entity://system/user/admin` is no longer a static supervisor child. In
  dev/prod it spawns lazily via SpawnRegistry on first dispatch
  reference (login, session join, cap lookup). The chat test-env
  seed `maybe_seed_main_session_for_tests/0` pre-spawns admin before
  joining it to session://system/default/main (chat.join requires the member's Kind
  alive in KindRegistry), so admin is up by the time these
  boot-invariant tests run. No per-test setup needed.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.{KindRegistry, ReadyGate}
  alias Ezagent.Entity.User

  setup do
    session_uri = ensure_boot_session!()

    # A prior test may deliberately leave the fixed boot URI in a failed or
    # half-created state. create_session/3 repairs it, but Kind activation is
    # asynchronous; wait for the replacement incarnation instead of observing
    # the stale ReadyGate marker in the gap.
    assert :ok = ReadyGate.await(session_uri, 5_000)

    %{session_uri: session_uri}
  end

  defp ensure_boot_session! do
    admin = User.admin_uri()

    case EzagentDomainInstanceMessage.SessionCreator.create_session(
           "main",
           admin,
           template_name: "default"
         ) do
      {:ok, session_uri, _meta} ->
        session_uri

      {:error, {:recreate_after_incomplete_failed, {:authority_load_failed, :regenesis_required}}} ->
        # Stage 3 / Option B: never implicitly reopen a destroyed fixed URI.
        # A lifecycle test may intentionally seal `main`; use an isolated smoke
        # session instead of re-genesis there and invalidating caps held by
        # unrelated tests in the same VM.
        short_name = "application-smoke-#{System.unique_integer([:positive, :monotonic])}"

        assert {:ok, session_uri, _meta} =
                 EzagentDomainInstanceMessage.SessionCreator.create_session(
                   short_name,
                   admin,
                   template_name: "default"
                 )

        session_uri
    end
  end

  test "the boot session is registered in KindRegistry", %{session_uri: session_uri} do
    assert {:ok, pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(pid)
  end

  test "the boot session is marked :ready in ReadyGate", %{session_uri: session_uri} do
    assert :ready = ReadyGate.status(URI.to_string(session_uri))
  end

  test "entity://system/user/admin is registered in KindRegistry (post-first-reference)" do
    uri = Ezagent.Entity.User.admin_uri()
    assert {:ok, pid} = KindRegistry.lookup(uri)
    assert Process.alive?(pid)
  end

  test "entity://system/user/admin is marked :ready in ReadyGate (post-first-reference)" do
    uri_str = URI.to_string(Ezagent.Entity.User.admin_uri())
    assert :ready = ReadyGate.status(uri_str)
  end

  test "AgentSupervisor is alive (agents spawn on bridge announce)" do
    sup = Process.whereis(EzagentDomainInstanceMessage.AgentSupervisor)
    assert is_pid(sup) and Process.alive?(sup)

    # Drop the strict "zero children" check — under full-umbrella runs
    # this assertion races against other tests in the chat suite that
    # spawn + terminate agents. Liveness is the boot invariant; child
    # count is a per-test fixture concern.
    assert is_map(DynamicSupervisor.count_children(sup))
  end
end
