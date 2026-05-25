defmodule Ezagent.CapabilityTest do
  use ExUnit.Case, async: true
  alias Ezagent.Capability
  import Ezagent.Test.CapHelper

  @user_uri URI.parse("entity://user/team-alpha/alice")
  @system_uri URI.parse("system://bootstrap")
  @other_uri URI.parse("system://other")
  @now ~U[2026-05-15 00:00:00Z]
  @ws_default URI.new!("workspace://team-alpha")

  describe "matches?/2" do
    test "exact match on all four fields" do
      cap =
        cap(
          kind: :echo,
          behavior: Ezagent.Behavior.Echo,
          instance: URI.parse("entity://agent/team-alpha/test_echo"),
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               cap,
               needed(
                 kind: :echo,
                 behavior: Ezagent.Behavior.Echo,
                 instance: URI.parse("entity://agent/team-alpha/test_echo")
               )
             )
    end

    test ":any wildcard matches any kind" do
      cap =
        cap(
          kind: :any,
          behavior: Ezagent.Behavior.Echo,
          instance: URI.parse("entity://agent/team-alpha/test_echo"),
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               cap,
               needed(
                 kind: :anything,
                 behavior: Ezagent.Behavior.Echo,
                 instance: URI.parse("entity://agent/team-alpha/test_echo")
               )
             )
    end

    test "quadruple-:any matches anything" do
      cap =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               cap,
               needed(
                 kind: :random_kind,
                 behavior: SomeMod,
                 instance: URI.parse("entity://agent/team-alpha/test_whatever"),
                 workspace_uri: URI.new!("workspace://anything")
               )
             )
    end

    test "non-match on kind" do
      cap =
        cap(
          kind: :echo,
          behavior: :any,
          instance: :any,
          granted_by: @user_uri,
          granted_at: @now
        )

      refute Capability.matches?(
               cap,
               needed(
                 kind: :chat,
                 behavior: Mod,
                 instance: URI.parse("entity://agent/team-alpha/test_x")
               )
             )
    end

    test "non-match on workspace (Phase 9 PR-3 / SPEC v3 §4.2)" do
      cap =
        cap(
          kind: :session,
          behavior: :any,
          instance: :any,
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: @user_uri,
          granted_at: @now
        )

      refute Capability.matches?(
               cap,
               needed(
                 kind: :session,
                 behavior: :any,
                 instance: URI.parse("session://default/system/main"),
                 workspace_uri: URI.new!("workspace://team-beta")
               )
             ),
             "concrete workspace cap must NOT match a different concrete workspace " <>
               "— SPEC v3 §4.2 workspace_match? requires URI string equality"
    end

    test ":any workspace cap matches any concrete needed workspace" do
      admin_workspace_cap =
        cap(
          kind: :session,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               admin_workspace_cap,
               needed(
                 kind: :session,
                 behavior: :any,
                 instance: URI.parse("session://default/system/main"),
                 workspace_uri: URI.new!("workspace://team-alpha")
               )
             )
    end
  end

  describe "revoke/2" do
    test "removes a non-admin cap" do
      c =
        cap(
          kind: :echo,
          behavior: :any,
          instance: :any,
          granted_by: @user_uri,
          granted_at: @now
        )

      caps = MapSet.new([c])
      assert {:ok, new_caps} = Capability.revoke(caps, c)
      assert MapSet.size(new_caps) == 0
    end

    test "refuses to revoke admin all-caps invariant" do
      admin =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: URI.parse("system://bootstrap/default"),
          granted_at: @now
        )

      caps = MapSet.new([admin])
      assert {:error, :cannot_revoke_admin} = Capability.revoke(caps, admin)
    end

    test "quadruple-:any but granted by non-bootstrap is revokable" do
      # Edge: same shape as admin but granted by a normal user — that's
      # a delegated grant, not the structural invariant, so revokable.
      c =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: @other_uri,
          granted_at: @now
        )

      caps = MapSet.new([c])
      assert {:ok, _new_caps} = Capability.revoke(caps, c)
    end

    test "triple-:any without :any workspace is NOT admin invariant (revokable)" do
      # Phase 9 PR-3 (SPEC v3 §4.4): admin_invariant? requires
      # workspace_uri: :any IN ADDITION to the three other :any fields.
      # A triple-:any with a concrete workspace is a workspace-admin
      # cap, not the structural bootstrap.
      c =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: @ws_default,
          granted_by: @system_uri,
          granted_at: @now
        )

      caps = MapSet.new([c])
      assert {:ok, _} = Capability.revoke(caps, c)
    end
  end

  describe "cap_for_action/3 (Phase 3d + Phase 9 PR-3 workspace)" do
    test "entity URI → workspace from entity_workspace_uri/1" do
      # Echo plugin pre-registers BehaviorRegistry at boot
      target = URI.new!("entity://agent/team-alpha/echo_default?action=echo.say")

      n = Capability.cap_for_action(Ezagent.Entity.Echo, :say, target)

      assert n.kind == :echo
      assert n.behavior == Ezagent.Behavior.Echo
      assert n.instance == URI.new!("entity://agent/team-alpha/echo_default")
      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "unknown action returns :unknown behavior" do
      target = URI.new!("entity://agent/team-alpha/echo_default?action=echo.say")
      n = Capability.cap_for_action(Ezagent.Entity.Echo, :nonexistent_action, target)
      assert n.behavior == :unknown
    end

    test "session://default/system/main?action=chat.send → workspace from URI path (SPEC v3 §3.6 PR-7)" do
      session_uri =
        URI.new!(
          "session://default/team-alpha/test-cap-for-action-#{System.unique_integer([:positive])}"
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")
      n = Capability.cap_for_action(Ezagent.Entity.Session, :send, target)

      assert n.kind == :session
      assert n.behavior == Ezagent.Behavior.Chat
      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "session URI workspace derivation is structural — no registry lookup (SPEC v3 §3.6 PR-7)" do
      # PR-7: workspace derivation moved from WorkspaceRegistry lookup
      # to structural URI extraction. An unbound session URI is fine —
      # the workspace comes from the path segment.
      unbound =
        URI.new!("session://default/team-alpha/never-bound-#{System.unique_integer([:positive])}")

      target = URI.new!("#{URI.to_string(unbound)}?action=chat.send")
      n = Capability.cap_for_action(Ezagent.Entity.Session, :send, target)

      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "workspace://X URI → workspace_uri is X itself" do
      # Use the System Kind as a kind_module stand-in — cap_for_action's
      # workspace derivation depends on the target URI's scheme, not
      # the kind_module. The kind_module's `type_name/0` only feeds
      # the returned map's `:kind` field. ezagent_core doesn't depend
      # on ezagent_domain_workspace, so we can't reference
      # `Ezagent.Entity.Workspace` here.
      target = URI.new!("workspace://team-alpha?action=workspace.read")
      n = Capability.cap_for_action(Ezagent.Entity.System, :read, target)

      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "system:// URI → workspace_uri is :any (cross-cutting)" do
      target = URI.new!("system://routing/default?action=add_rule")
      n = Capability.cap_for_action(Ezagent.Entity.System, :add_rule, target)

      assert n.workspace_uri == :any
    end

    test "admin all-cap matches the needed shape (closed-loop integration)" do
      [admin_cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))

      session_uri =
        URI.new!(
          "session://default/team-alpha/admin-closeloop-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, "workspace://team-alpha")

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")
      n = Capability.cap_for_action(Ezagent.Entity.Session, :send, target)

      assert Capability.matches?(admin_cap, n)
    end
  end

  describe "scope-bounded instance tuples (Phase 7 PR 42 / D7-3)" do
    defp scoped_cap(instance) do
      cap(
        kind: :session,
        behavior: :any,
        instance: instance,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: ~U[2026-05-18 00:00:00Z]
      )
    end

    defp needed_session(target_str) do
      # SPEC v3 §3.6 (Phase 9 PR-7) — workspace derivation is
      # structural; no WorkspaceRegistry.bind needed.
      %URI{} = uri = URI.new!(target_str)
      Capability.cap_for_action(Ezagent.Entity.Session, :send, uri)
    end

    test "{:within_session, S} matches needed targeting URI exactly equal to S" do
      session_uri =
        URI.new!("session://default/team-alpha/main-w1-#{System.unique_integer([:positive])}")

      c = scoped_cap({:within_session, session_uri})

      assert Capability.matches?(
               c,
               needed_session("#{URI.to_string(session_uri)}?action=chat.send")
             )
    end

    test "{:within_session, S} matches needed whose instance is a sub-URI of S (path prefix)" do
      # Note: under SPEC v2 1-segment-authority session URIs, the
      # `instance/1` extractor strips the path entirely, so this
      # sub-URI test exercises the {:within_session, _} string-prefix
      # check directly via a manually-constructed `needed` map.
      session_uri =
        URI.new!("session://default/team-alpha/main-w2-#{System.unique_integer([:positive])}")

      c = scoped_cap({:within_session, session_uri})

      needed_subpath =
        needed(
          kind: :session,
          behavior: :any,
          instance: URI.parse("#{URI.to_string(session_uri)}/sub-path"),
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      assert Capability.matches?(c, needed_subpath)
    end

    test "{:within_session, S} does NOT match needed in a different session (V3.2 scope leak)" do
      uniq = System.unique_integer([:positive])
      c = scoped_cap({:within_session, URI.new!("session://default/team-alpha/main-w3-#{uniq}")})

      refute Capability.matches?(
               c,
               needed_session("session://default/team-alpha/other-w3-#{uniq}?action=chat.send")
             )
    end

    test "{:within_session, session://default/system/main} does NOT false-match session://default/system/main2 (prefix boundary)" do
      session_uri =
        URI.new!("session://default/team-alpha/main-w4-#{System.unique_integer([:positive])}")

      c = scoped_cap({:within_session, session_uri})

      needed_neighbor =
        needed(
          kind: :session,
          behavior: :any,
          instance: URI.parse("#{URI.to_string(session_uri)}2"),
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      refute Capability.matches?(c, needed_neighbor),
             "{:within_session, session://default/team-alpha/main-w4} must not match session://default/team-alpha/main-w42 — " <>
               "prefix check requires '/' boundary, not raw startsWith"
    end

    test "{:spawned_by, P} with no lineage recorded denies (deny-when-absent)" do
      # PR 40 ships Ezagent.AgentLineage registry; without a recorded
      # spawn relationship, the cap denies. This is the new
      # placeholder-equivalent (was hard-coded false in PR 42; now
      # ETS lookup that's empty).
      c =
        scoped_cap(
          {:spawned_by, URI.new!("entity://agent/team-alpha/test_orchestrator-unrecorded")}
        )

      needed_any_agent =
        needed(
          kind: :agent,
          behavior: :any,
          instance:
            URI.parse(
              "entity://agent/team-alpha/test_worker-no-lineage-#{System.unique_integer([:positive])}"
            ),
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      refute Capability.matches?(c, needed_any_agent),
             "{:spawned_by, _} cap must deny when AgentLineage has no record " <>
               "of the spawn relationship — deny-when-absent is the conservative default"
    end

    test "{:spawned_by, P} matches when lineage IS recorded (PR 40 real impl)" do
      orchestrator =
        URI.new!(
          "entity://agent/team-alpha/test_orchestrator-#{System.unique_integer([:positive])}"
        )

      worker =
        URI.new!("entity://agent/team-alpha/test_worker-#{System.unique_integer([:positive])}")

      :ok = Ezagent.AgentLineage.record(worker, orchestrator)

      # Sanity: verify the record landed (catches scope_cap kind
      # mismatch or test sandbox confusion before we blame the
      # matches? code).
      assert {:ok, returned} = Ezagent.AgentLineage.lookup(worker)

      assert URI.to_string(returned) == URI.to_string(orchestrator),
             "AgentLineage.lookup returned wrong orchestrator URI"

      assert Ezagent.AgentLineage.spawned_in_lineage?(worker, orchestrator),
             "AgentLineage.spawned_in_lineage? returned false despite the record"

      c =
        cap(
          kind: :agent,
          behavior: :any,
          instance: {:spawned_by, orchestrator},
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: URI.parse("entity://user/system/admin"),
          granted_at: ~U[2026-05-18 00:00:00Z]
        )

      needed_worker =
        needed(
          kind: :agent,
          behavior: :any,
          instance: worker,
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      assert Capability.matches?(c, needed_worker),
             "{:spawned_by, orchestrator} cap must match when worker was recorded as " <>
               "spawned by orchestrator (PR 40 real lineage impl)"

      # Clean up so this test doesn't leak ETS state to other tests
      Ezagent.AgentLineage.forget(worker)
    end

    test "{:spawned_by, P} does NOT match an unrelated agent (lineage isolation)" do
      orchestrator_a =
        URI.new!("entity://agent/team-alpha/test_orch-a-#{System.unique_integer([:positive])}")

      orchestrator_b =
        URI.new!("entity://agent/team-alpha/test_orch-b-#{System.unique_integer([:positive])}")

      worker_of_a =
        URI.new!(
          "entity://agent/team-alpha/test_worker-of-a-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.AgentLineage.record(worker_of_a, orchestrator_a)

      cap_for_b =
        cap(
          kind: :agent,
          behavior: :any,
          instance: {:spawned_by, orchestrator_b},
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: URI.parse("entity://user/system/admin"),
          granted_at: ~U[2026-05-18 00:00:00Z]
        )

      needed_worker_of_a =
        needed(
          kind: :agent,
          behavior: :any,
          instance: worker_of_a,
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      refute Capability.matches?(cap_for_b, needed_worker_of_a),
             "orchestrator B's {:spawned_by, B} cap must NOT match a worker spawned by " <>
               "orchestrator A — lineage isolation prevents cross-orchestrator authority"

      Ezagent.AgentLineage.forget(worker_of_a)
    end

    test "scope tuple cap with wrong kind does NOT match (scope only narrows, never broadens)" do
      session_uri =
        URI.new!("session://default/team-alpha/wrong-kind-#{System.unique_integer([:positive])}")

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, "workspace://team-alpha")

      c =
        cap(
          kind: :workspace,
          behavior: :any,
          instance: {:within_session, session_uri},
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: URI.parse("entity://user/system/admin"),
          granted_at: ~U[2026-05-18 00:00:00Z]
        )

      refute Capability.matches?(
               c,
               Capability.cap_for_action(
                 Ezagent.Entity.Session,
                 :send,
                 URI.new!("#{URI.to_string(session_uri)}?action=chat.send")
               )
             ),
             "scope-tuple cap with wrong kind must NOT match"
    end
  end

  describe "{:within_workspace, W} instance shape (Phase 7 completion PR-1 / SPEC §1.4)" do
    defp ws_cap(workspace_uri, kind \\ :agent_template) do
      cap(
        kind: kind,
        behavior: Ezagent.Behavior.Template,
        instance: {:within_workspace, workspace_uri},
        workspace_uri: :any,
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: ~U[2026-05-22 00:00:00Z]
      )
    end

    test "matches a template URI whose workspace segment equals W" do
      c = ws_cap(URI.new!("workspace://team-alpha"))

      assert Capability.matches?(
               c,
               needed(
                 kind: :agent_template,
                 behavior: Ezagent.Behavior.Template,
                 instance: URI.new!("template://agent/team-alpha/cc-orch"),
                 workspace_uri: :any
               )
             )
    end

    test "denies a template URI in a DIFFERENT workspace (two-tenant isolation)" do
      c = ws_cap(URI.new!("workspace://team-beta"))

      refute Capability.matches?(
               c,
               needed(
                 kind: :agent_template,
                 behavior: Ezagent.Behavior.Template,
                 instance: URI.new!("template://agent/team-alpha/cc-orch"),
                 workspace_uri: :any
               )
             ),
             "{:within_workspace, team-beta} must NOT match a template in team-alpha"
    end

    test "matches a 3-segment session-template URI in the same workspace" do
      c = ws_cap(URI.new!("workspace://team-alpha"), :session_template)

      assert Capability.matches?(
               c,
               needed(
                 kind: :session_template,
                 behavior: Ezagent.Behavior.Template,
                 instance:
                   URI.new!(
                     "template://session/team-alpha/code-review@" <> String.duplicate("a", 64)
                   ),
                 workspace_uri: :any
               )
             )
    end

    test "does NOT match a cross-cutting system:// URI — only :any is a true wildcard" do
      # `kind: :any` on the cap isolates the test to the INSTANCE
      # dimension — proving `{:within_workspace, _}` itself rejects a
      # workspace-less system:// URI (whose `workspace_of/1` is `:any`).
      c =
        cap(
          kind: :any,
          behavior: :any,
          instance: {:within_workspace, URI.new!("workspace://team-alpha")},
          workspace_uri: :any,
          granted_by: URI.parse("entity://user/system/admin"),
          granted_at: ~U[2026-05-22 00:00:00Z]
        )

      refute Capability.matches?(
               c,
               needed(
                 kind: :system,
                 behavior: :any,
                 instance: URI.new!("system://routing/default"),
                 workspace_uri: :any
               )
             ),
             "{:within_workspace, _} narrows; it must not match a workspace-less system:// URI"
    end
  end
end
