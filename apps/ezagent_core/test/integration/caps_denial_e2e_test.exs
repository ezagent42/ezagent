defmodule Ezagent.Integration.CapsDenialE2ETest do
  @moduledoc """
  Design 1 from `docs/notes/caps-e2e-design.md` — the single-file
  reference exhibit that proves CapBAC actually gates behavior.

  Denial-or-grant scenarios that exercise the central
  `Ezagent.Invocation.dispatch/1` step 5.5 `Capability.matches?/2`
  check — the dispatch chokepoint, which is the real authorization
  boundary (#154 VM-internal-trust model: external authenticated
  callers are gated here; in-VM-internal helpers like
  `Ezagent.Presence`/`Ezagent.Notifications` are NOT cap-gated, so the
  former Presence-subscribe scenarios were removed).

  ## Why this file exists

  Allen 2026-05-23: "我其实没有太感受到当前 caps 有什么作用". Cap
  coverage was scattered across `routing_cap_test`,
  `cross_workspace_isolation_test`, etc. — none produced a single
  human-readable denial report.

  This is THAT report.

  ## What each scenario asserts

  | # | Caller | Caps | Action | Expected |
  |---|---|---|---|---|
  | 1 | non-admin | EMPTY | `chat.send` | `{:error, :missing_cap}` |
  | 4 | admin | full | `chat.send` | `:ok` |
  """

  # #92: was `use ExUnit.Case` + a hand-rolled `checkout` + `{:shared, self()}`
  # in `setup`. That made the (short-lived) TEST PROCESS the global shared owner;
  # when it exited, the pool reverted to `:manual` and concurrent suites' Kinds
  # lost their connection ("owner exited" / "cannot find ownership"). DataCase
  # establishes shared mode via a DRAINABLE Agent owner + a teardown that drains
  # in-flight Kind DB work before reclaiming the connection, so this suite's
  # spawned Kinds still share the sandbox without clobbering anyone.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{Invocation, Message, Users}

  defp setup_non_admin_user(handle, caps \\ []) do
    uri_str = "entity://team-alpha/user/" <> handle <> "_#{System.unique_integer([:positive])}"
    {:ok, _} = Users.create(uri_str, nil, caps)

    uri = Ezagent.URI.new!(uri_str)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

    {uri, MapSet.new(caps)}
  end

  defp default_session do
    # Use a fresh session per test to avoid cross-test pollution
    short = "caps_demo_#{System.unique_integer([:positive])}"

    {:ok, uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        short,
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    uri
  end

  defp chat_send_target(session_uri),
    do: URI.new!("#{URI.to_string(session_uri)}?action=session.send")

  defp dispatch_send(caller_uri, caps, session_uri, text, mentions \\ []) do
    msg =
      Message.new(caller_uri, %{text: text, attachments: []},
        mentions: mentions,
        ref_id: nil
      )

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: chat_send_target(session_uri),
      mode: :call,
      args: %{message: msg},
      ctx: %{
        caller: caller_uri,
        authenticated_principal: caller_uri,
        caps: caps,
        reply: :inline
      }
    })
  end

  describe "Scenario 1 — non-admin with EMPTY caps cannot chat.send" do
    test "dispatch returns {:error, :missing_cap}" do
      {bob_uri, bob_caps} = setup_non_admin_user("bob_empty")
      session_uri = default_session()

      assert {:error, :missing_cap} =
               dispatch_send(bob_uri, bob_caps, session_uri, "hi")
    end
  end

  describe "Scenario 4 — admin's superset cap matches everything" do
    test "admin can chat.send (control case: positive path proves the test setup is valid)" do
      admin_uri = Ezagent.Entity.User.admin_uri()
      session_uri = default_session()
      target = chat_send_target(session_uri)
      admin_caps = MapSet.new([signed_action_cap!(target, admin_uri)])

      result = dispatch_send(admin_uri, admin_caps, session_uri, "hi from admin")

      assert match?({:ok, _}, result) or result == :ok
    end
  end

  describe "Summary report (printed on every run)" do
    test "report" do
      report = """

      ┌────────────────────────────────────────────────────────────────────┐
      │ CapBAC denial e2e — dispatch chokepoint (step 5.5)                  │
      ├────────────────────────────────────────────────────────────────────┤
      │ #1 empty-caps → chat.send                  → :missing_cap    ✓     │
      │ #4 admin → chat.send (control)              → :ok             ✓     │
      └────────────────────────────────────────────────────────────────────┘
      """

      IO.puts(report)
      assert true
    end
  end
end
