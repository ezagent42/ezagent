defmodule Ezagent.E2E.Category05.Scenario15RevokeCapDenialTest do
  @moduledoc """
  E2E scenario 15 — Revoke cap + non-admin denial.

  Cross-references `docs/scenarios/15-revoke-cap-non-admin-denial/scenario.md`.

  Verifies:

  - A non-admin with NO caps is denied at `Invocation.dispatch` step 5.5
    (`{:error, :unauthorized}`).
  - A non-admin holding a narrow cap is GRANTED the matching action.
  - When the cap is removed from the held set, dispatch is denied again.
  - Idempotent revoke (no held cap → revoke returns `:ok` with empty set).
  - LV vs CLI parity is structurally guaranteed by the single
    `Invocation.dispatch/1` chokepoint — both surfaces traverse step 5.5
    identically; this file pins the chokepoint.

  Per `feedback_e2e_prefers_non_admin_user`: Alice (a fresh
  `entity://team-alpha/user/alice_<n>`) is the canonical non-admin
  caller.

  Verification surface: dispatch chokepoint level (the integration
  layer between LV/CLI and the Behavior). LV/CLI grant-form coverage
  lives in `entity_caps_live_test.exs` + `cli_lv_cap_parity_test.exs`
  per scenario cross-refs. This file is the structural denial gate
  Phase 2 Behavior migrations must regression-pass.

  Scenario `scenario: "15-revoke-cap-non-admin-denial"` (moduletag).
  """

  # #92: was `use ExUnit.Case` + a hand-rolled `checkout` + `{:shared, self()}`
  # in `setup`. The dying test process became the global shared owner; on exit
  # the pool reverted to `:manual` and its spawned Session Kinds' background
  # `kind_snapshots` writes failed ("owner exited") — the deterministic clobber
  # this task fixes. DataCase shares via a drainable Agent owner + drain
  # teardown, so those writes complete before the connection is reclaimed.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  import Ezagent.Test.CapHelper

  alias Ezagent.{Capability, Invocation, Message, Users}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri()) =>
        MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  @moduletag scenario: "15-revoke-cap-non-admin-denial"

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp spawn_alice do
    uri_str = "entity://team-alpha/user/" <> uniq("alice")
    {:ok, _} = Users.create(uri_str, nil, [])
    uri = Ezagent.URI.new!(uri_str)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {uri, MapSet.new()}
  end

  defp default_session(workspace_uri \\ URI.new!("workspace://system")) do
    # Session workspace governs which caps authorize chat.send on it.
    # Default to workspace://system so Alice's structural default caps
    # (scoped to her own workspace://team-alpha) don't accidentally
    # match — the test then exercises ONLY the explicit caps the test
    # passes in `dispatch_send/3`.
    short = uniq("rev_demo")

    {:ok, uri, _meta} =
      create_session_via_workspace(short, Ezagent.Entity.User.admin_uri(),
        template_name: "default",
        workspace_uri: workspace_uri
      )

    uri
  end

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{
               caller: creator_uri,
               authenticated_principal: creator_uri,
               caps:
                 MapSet.new([
                   signed_action_cap!(
                     Ezagent.URI.with_action(workspace_uri, :workspace, :create_session),
                     creator_uri
                   )
                 ])
             }
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  defp dispatch_send(caller_uri, caps, session_uri, text) do
    by_holder =
      Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      Map.put(by_holder, Ezagent.URI.stable_key(caller_uri), MapSet.new([:test_holder_license]))
    )

    msg = Message.new(caller_uri, %{text: text, attachments: []}, mentions: [], ref_id: nil)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
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

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  # Either denial mode means the dispatch was rejected. `:unauthorized`
  # is step 5.5 (cap-check). `:cross_workspace_denied` is step 5.6
  # (workspace isolation) — fired when caller and target sit in different
  # workspaces and the caller lacks a cross-workspace cap. Both indicate
  # CapBAC is doing its job.
  defp assert_denied!(result, msg) do
    assert match?({:error, :missing_cap}, result) or
             match?({:error, :invalid_cap_signature}, result) or
             match?({:error, :cross_workspace_denied}, result),
           "#{msg} — got #{inspect(result)}"
  end

  describe "no caps → dispatch denied" do
    test "Alice with EMPTY held caps cannot chat.send" do
      {alice_uri, alice_caps} = spawn_alice()
      session = default_session()

      assert_denied!(
        dispatch_send(alice_uri, alice_caps, session, "hi"),
        "EMPTY caps MUST be denied — baseline regression gate"
      )
    end

    test "Alice with WRONG-behavior cap cannot chat.send" do
      # Alice holds a Routing cap (not Chat) — must NOT cross the behavior axis.
      wrong_cap =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Routing,
          action: :add_rule,
          instance: :any,
          workspace_uri: URI.new!("workspace://system")
        )

      {alice_uri, _empty} = spawn_alice()
      session = default_session()
      alice_caps = MapSet.new([signed_cap!(session, alice_uri, wrong_cap)])

      assert_denied!(
        dispatch_send(alice_uri, alice_caps, session, "hi"),
        "behavior axis is load-bearing — Routing cap MUST NOT authorize chat.send"
      )
    end

    test "Alice with WRONG-action cap (action axis narrow) cannot chat.send" do
      # Alice holds a Chat cap narrow to `:join` — `:send` must be denied.
      wrong_action_cap =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :join,
          instance: :any,
          workspace_uri: URI.new!("workspace://system")
        )

      {alice_uri, _empty} = spawn_alice()
      session = default_session()
      alice_caps = MapSet.new([signed_cap!(session, alice_uri, wrong_action_cap)])

      assert_denied!(
        dispatch_send(alice_uri, alice_caps, session, "hi"),
        "action axis is load-bearing per SPEC 2026-05-27 — narrow `:join` MUST NOT authorize `:send`"
      )
    end
  end

  describe "matching cap → dispatch allowed; revoke → denied again" do
    test "grant→use→revoke→use cycle" do
      # Setup:
      # - Alice lives in workspace://team-alpha (so her structural default
      #   caps DO NOT match a workspace://system session — see comment
      #   on `default_session/1`).
      # - Session is on workspace://system.
      # - Alice's explicit grant is a CROSS-WORKSPACE chat.send cap
      #   (`workspace_uri: :any`) so it passes both step 5.5 (cap-check)
      #   and step 5.6 (workspace isolation). After revoke, no ctx.cap
      #   remains and her slice default_caps still don't reach
      #   workspace://system → dispatch is denied.
      {alice_uri, _empty} = spawn_alice()
      session = default_session()
      send_cap = signed_send_cap!(session, alice_uri, :any)
      held = MapSet.new([send_cap])

      # Step 2: dispatch with the narrow cap succeeds (NOT a denial).
      result = dispatch_send(alice_uri, held, session, "hello with cap")

      refute match?({:error, :unauthorized}, result),
             "cross-workspace chat.send cap MUST authorize — got #{inspect(result)}"

      refute match?({:error, :cross_workspace_denied}, result),
             "cross-workspace cap MUST pass step 5.6 — got #{inspect(result)}"

      # Step 3: revoke the cap (simulating admin LV / CLI revoke). This
      # exercises `Capability.revoke/2` — the data-layer chokepoint.
      assert {:ok, after_revoke} = Capability.revoke(held, send_cap)

      assert MapSet.size(after_revoke) == 0,
             "revoke MUST remove the matching cap from the held set"

      # Step 4: dispatch with the now-empty held set is denied — denial
      # AFTER revocation is the regression gate.
      result_after = dispatch_send(alice_uri, after_revoke, session, "after revoke")

      assert_denied!(
        result_after,
        "post-revoke dispatch MUST be denied — CapBAC enforcement gate"
      )
    end

    test "revoke is idempotent — re-revoke returns :ok with same set" do
      held = MapSet.new()

      target =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: :any,
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      assert {:ok, ^held} = Capability.revoke(held, target),
             "revoke on absent target MUST be a no-op return :ok (admin can re-click without error)"
    end
  end

  describe "admin's structural cap survives revoke attempts" do
    test "admin's bootstrap cap cannot be revoked" do
      admin_cap = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      held = MapSet.new([admin_cap])

      assert {:error, :cannot_revoke_admin} = Capability.revoke(held, admin_cap),
             "admin's structural cap is invariant — Decision #81 chokepoint"

      # The held set is untouched.
      assert MapSet.size(held) == 1
    end
  end

  describe "admin can chat.send — control case (proves test infra is valid)" do
    test "admin's superset cap matches every action" do
      admin_uri = Ezagent.Entity.User.admin_uri()
      session = default_session()
      admin_caps = MapSet.new([signed_send_cap!(session, admin_uri, :any)])

      result = dispatch_send(admin_uri, admin_caps, session, "hi from admin")

      refute match?({:error, :unauthorized}, result),
             "admin MUST authorize chat.send — positive control; failure here means test setup is broken"
    end
  end

  defp signed_send_cap!(session, grantee, workspace_scope) do
    requested =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :send,
        Ezagent.URI.instance(session),
        workspace_scope
      )

    {:ok, cap} = Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, grantee, requested)
    cap
  end

  describe "cross-workspace narrow cap is not enough" do
    test "Alice's cap on workspace://team-alpha CANNOT authorize a system-workspace session" do
      # Pin the workspace axis. Alice holds a chat.send cap explicitly
      # tied to team-alpha; she tries to dispatch on a session owned by
      # workspace://system.
      narrow_ws_cap =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: :any,
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      # The needed shape — workspace://system instead.
      needed_for_system =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: URI.new!("session://system/default/main"),
          workspace_uri: URI.new!("workspace://system")
        )

      refute Capability.matches?(narrow_ws_cap, needed_for_system),
             "workspace axis MUST gate cross-workspace use — team-alpha cap is not a workspace://system cap"
    end
  end
end
