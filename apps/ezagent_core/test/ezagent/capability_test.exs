defmodule Ezagent.CapabilityTest do
  # remediation C-B (#114) — `Ezagent.AgentLineage.record/2` is now
  # write-through to the durable `agent_lineage` SQLite table, so the
  # `{:spawned_by, P}` lineage tests need an Ecto sandbox connection.
  # DataCase sets one up per test; `async: false` because it shares the
  # global AgentLineage ETS cache + a sandbox connection.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only
  alias Ezagent.Capability
  import Ezagent.Test.CapHelper

  @user_uri Ezagent.URI.new!("entity://team-alpha/user/alice")
  @system_uri Ezagent.URI.new!("system://bootstrap")
  @other_uri Ezagent.URI.new!("system://other")
  @now ~U[2026-05-15 00:00:00Z]
  @ws_default URI.new!("workspace://team-alpha")

  describe "matches?/2" do
    test "exact match on all four fields" do
      cap =
        cap(
          kind: :py_agent,
          behavior: Ezagent.ActionSet.PyAgent,
          instance: Ezagent.URI.new!("entity://team-alpha/agent/test_py"),
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               cap,
               needed(
                 kind: :py_agent,
                 behavior: Ezagent.ActionSet.PyAgent,
                 instance: Ezagent.URI.new!("entity://team-alpha/agent/test_py")
               )
             )
    end

    test ":any wildcard matches any kind" do
      cap =
        cap(
          kind: :any,
          behavior: Ezagent.ActionSet.PyAgent,
          instance: Ezagent.URI.new!("entity://team-alpha/agent/test_py"),
          granted_by: @user_uri,
          granted_at: @now
        )

      assert Capability.matches?(
               cap,
               needed(
                 kind: :anything,
                 behavior: Ezagent.ActionSet.PyAgent,
                 instance: Ezagent.URI.new!("entity://team-alpha/agent/test_py")
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
                 instance: Ezagent.URI.new!("entity://team-alpha/agent/test_whatever"),
                 workspace_uri: URI.new!("workspace://anything")
               )
             )
    end

    test "non-match on kind" do
      cap =
        cap(
          kind: :py_agent,
          behavior: :any,
          instance: :any,
          granted_by: @user_uri,
          granted_at: @now
        )

      refute Capability.matches?(
               cap,
               needed(
                 kind: :session,
                 behavior: Mod,
                 instance: Ezagent.URI.new!("entity://team-alpha/agent/test_x")
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
                 instance: Ezagent.URI.new!("session://system/default/main"),
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
                 instance: Ezagent.URI.new!("session://system/default/main"),
                 workspace_uri: URI.new!("workspace://team-alpha")
               )
             )
    end
  end

  describe "authorizing_cap/2" do
    test "is the shared provenance-aware full predicate used by runtime and preflights" do
      target = Ezagent.URI.new!("session://team-alpha/generic/shared-predicate")

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :join,
          instance: target,
          workspace_uri: @ws_default
        )

      valid =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :join,
          instance: target,
          workspace_uri: @ws_default,
          granted_by: @user_uri,
          granted_at: @now
        )

      wrong_action = %{valid | action: :leave}
      legacy_system_grant = %{valid | granted_by: @system_uri}

      assert :error =
               Capability.Authorization.authorizing_cap(
                 @user_uri,
                 [wrong_action, valid],
                 needed
               )

      refute Capability.Authorization.authorizes?(@user_uri, MapSet.new([valid]), needed)
      refute Capability.Authorization.authorizes?(@user_uri, [wrong_action], needed)
      refute Capability.Authorization.authorizes?(@user_uri, [legacy_system_grant], needed)
    end
  end

  describe "revoke/2" do
    test "removes a non-admin cap" do
      c =
        cap(
          kind: :py_agent,
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
      # #154 genesis collapse — the genesis trust root is the admin entity
      # self-granting its all-caps wildcard (granted_by the admin URI), not the
      # eliminated `system://bootstrap` principal.
      admin =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: @now
        )

      caps = MapSet.new([admin])
      assert {:error, :cannot_revoke_admin} = Capability.revoke(caps, admin)
    end

    test "quadruple-:any but granted by a non-admin entity is revokable" do
      # Edge: same shape as the genesis admin cap but granted by a normal user —
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
      # The py plugin pre-registers BehaviorRegistry at boot (P4b: py folded onto
      # the unified Entity.Agent Kind; its py-namespaced :py_configure resolves).
      target = URI.new!("entity://team-alpha/agent/py_default?action=py.py_configure")

      n = Capability.cap_for_action(Ezagent.Entity.Agent, :py_configure, target)

      # `:any` kind axis is substituted with the host Kind's type_name (`:agent`).
      assert n.kind == :agent
      assert n.behavior == Ezagent.ActionSet.PyAgent
      assert n.instance == URI.new!("entity://team-alpha/agent/py_default")
      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "unknown action returns :unknown behavior" do
      target = URI.new!("entity://team-alpha/agent/py_default?action=py.py_configure")
      n = Capability.cap_for_action(Ezagent.Entity.Agent, :nonexistent_action, target)
      assert n.behavior == :unknown
    end

    test "session://system/default/main?action=session.send → workspace from URI path (SPEC v3 §3.6 PR-7)" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/test-cap-for-action-#{System.unique_integer([:positive])}"
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
      n = Capability.cap_for_action(Ezagent.Entity.Session, :send, target)

      assert n.kind == :session
      assert n.behavior == Ezagent.ActionSet.Session
      assert URI.to_string(n.workspace_uri) == "workspace://team-alpha"
    end

    test "session URI workspace derivation is structural — no registry lookup (SPEC v3 §3.6 PR-7)" do
      # PR-7: workspace derivation moved from WorkspaceRegistry lookup
      # to structural URI extraction. An unbound session URI is fine —
      # the workspace comes from the path segment.
      unbound =
        URI.new!("session://team-alpha/default/never-bound-#{System.unique_integer([:positive])}")

      target = URI.new!("#{URI.to_string(unbound)}?action=session.send")
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
      [admin_cap] = MapSet.to_list(MapSet.new([Ezagent.Capability.admin_genesis_cap()]))

      session_uri =
        URI.new!(
          "session://team-alpha/default/admin-closeloop-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, "workspace://team-alpha")

      target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
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
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
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
        URI.new!("session://team-alpha/default/main-w1-#{System.unique_integer([:positive])}")

      c = scoped_cap({:within_session, session_uri})

      assert Capability.matches?(
               c,
               needed_session("#{URI.to_string(session_uri)}?action=session.send")
             )
    end

    test "{:within_session, S} matches needed whose instance is a sub-URI of S (path prefix)" do
      # Note: under SPEC v2 1-segment-authority session URIs, the
      # `instance/1` extractor strips the path entirely, so this
      # sub-URI test exercises the {:within_session, _} string-prefix
      # check directly via a manually-constructed `needed` map.
      session_uri =
        URI.new!("session://team-alpha/default/main-w2-#{System.unique_integer([:positive])}")

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
      c = scoped_cap({:within_session, URI.new!("session://team-alpha/default/main-w3-#{uniq}")})

      refute Capability.matches?(
               c,
               needed_session("session://team-alpha/default/other-w3-#{uniq}?action=session.send")
             )
    end

    test "{:within_session, session://system/default/main} does NOT false-match session://system/default/main2 (prefix boundary)" do
      session_uri =
        URI.new!("session://team-alpha/default/main-w4-#{System.unique_integer([:positive])}")

      c = scoped_cap({:within_session, session_uri})

      needed_neighbor =
        needed(
          kind: :session,
          behavior: :any,
          instance: URI.parse("#{URI.to_string(session_uri)}2"),
          workspace_uri: URI.new!("workspace://team-alpha")
        )

      refute Capability.matches?(c, needed_neighbor),
             "{:within_session, session://team-alpha/default/main-w4} must not match session://team-alpha/default/main-w42 — " <>
               "prefix check requires '/' boundary, not raw startsWith"
    end

    test "{:spawned_by, P} with no lineage recorded denies (deny-when-absent)" do
      # PR 40 ships Ezagent.AgentLineage registry; without a recorded
      # spawn relationship, the cap denies. This is the new
      # placeholder-equivalent (was hard-coded false in PR 42; now
      # ETS lookup that's empty).
      c =
        scoped_cap(
          {:spawned_by, URI.new!("entity://team-alpha/agent/test_orchestrator-unrecorded")}
        )

      needed_any_agent =
        needed(
          kind: :agent,
          behavior: :any,
          instance:
            URI.parse(
              "entity://team-alpha/agent/test_worker-no-lineage-#{System.unique_integer([:positive])}"
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
          "entity://team-alpha/agent/test_orchestrator-#{System.unique_integer([:positive])}"
        )

      worker =
        URI.new!("entity://team-alpha/agent/test_worker-#{System.unique_integer([:positive])}")

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
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
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
        URI.new!("entity://team-alpha/agent/test_orch-a-#{System.unique_integer([:positive])}")

      orchestrator_b =
        URI.new!("entity://team-alpha/agent/test_orch-b-#{System.unique_integer([:positive])}")

      worker_of_a =
        URI.new!(
          "entity://team-alpha/agent/test_worker-of-a-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.AgentLineage.record(worker_of_a, orchestrator_a)

      cap_for_b =
        cap(
          kind: :agent,
          behavior: :any,
          instance: {:spawned_by, orchestrator_b},
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
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
        URI.new!("session://team-alpha/default/wrong-kind-#{System.unique_integer([:positive])}")

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, "workspace://team-alpha")

      c =
        cap(
          kind: :workspace,
          behavior: :any,
          instance: {:within_session, session_uri},
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: ~U[2026-05-18 00:00:00Z]
        )

      refute Capability.matches?(
               c,
               Capability.cap_for_action(
                 Ezagent.Entity.Session,
                 :send,
                 URI.new!("#{URI.to_string(session_uri)}?action=session.send")
               )
             ),
             "scope-tuple cap with wrong kind must NOT match"
    end
  end

  describe "{:within_workspace, W} instance shape (Phase 7 completion PR-1 / SPEC §1.4)" do
    defp ws_cap(workspace_uri, kind \\ :agent_template) do
      cap(
        kind: kind,
        behavior: Ezagent.ActionSet.Template,
        instance: {:within_workspace, workspace_uri},
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-22 00:00:00Z]
      )
    end

    test "matches a template URI whose workspace segment equals W" do
      c = ws_cap(URI.new!("workspace://team-alpha"))

      assert Capability.matches?(
               c,
               needed(
                 kind: :agent_template,
                 behavior: Ezagent.ActionSet.Template,
                 instance: URI.new!("template://team-alpha/agent/cc-orch"),
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
                 behavior: Ezagent.ActionSet.Template,
                 instance: URI.new!("template://team-alpha/agent/cc-orch"),
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
                 behavior: Ezagent.ActionSet.Template,
                 instance:
                   URI.new!(
                     "template://team-alpha/session/code-review@" <> String.duplicate("a", 64)
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
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
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

  describe "Phase-4 signing fields serialization" do
    test "all scope-tuple instance variants round-trip through the caps_json wire shape" do
      scopes = [
        {:within_session, URI.new!("session://team-alpha/default/scoped")},
        {:within_workspace, URI.new!("workspace://team-alpha")},
        {:spawned_by, URI.new!("entity://team-alpha/agent/orchestrator")}
      ]

      for instance <- scopes do
        original = %Capability{
          kind: :agent,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: instance,
          workspace_uri: @ws_default,
          granted_by: @user_uri,
          granted_at: @now
        }

        restored =
          original
          |> Capability.to_map()
          |> Jason.encode!()
          |> Jason.decode!()
          |> Capability.from_map()

        assert restored == original
      end
    end

    test "scope tuples are rejected on workspace and grant-provenance axes" do
      scope = {:within_workspace, @ws_default}

      base = %Capability{
        kind: :agent,
        behavior: Ezagent.ActionSet.Session,
        action: :send,
        instance: :any,
        workspace_uri: @ws_default,
        granted_by: @user_uri,
        granted_at: @now
      }

      assert_raise ArgumentError, ~r/workspace_uri/, fn ->
        Capability.to_map(%{base | workspace_uri: scope})
      end

      assert_raise ArgumentError, ~r/granted_by/, fn ->
        Capability.to_map(%{base | granted_by: scope})
      end

      encoded_scope = %{"scope" => "within_workspace", "uri" => URI.to_string(@ws_default)}
      stored = Capability.to_map(base)

      assert_raise ArgumentError, ~r/workspace_uri/, fn ->
        Capability.from_map(Map.put(stored, "workspace_uri", encoded_scope))
      end

      assert_raise ArgumentError, ~r/granted_by/, fn ->
        Capability.from_map(Map.put(stored, "granted_by", encoded_scope))
      end
    end

    test "nil signing and grantee fields round-trip through the caps_json wire shape" do
      original = %Capability{
        kind: :user,
        behavior: Ezagent.ActionSet.Session,
        action: :send,
        instance: :any,
        workspace_uri: @ws_default,
        granted_by: @user_uri,
        granted_at: @now
      }

      stored = Capability.to_map(original)

      assert stored["signature"] == nil
      assert stored["key_id"] == nil
      assert stored["grantee_uri"] == nil

      restored = stored |> Jason.encode!() |> Jason.decode!() |> Capability.from_map()

      assert restored == original
      assert restored.signature == nil
      assert restored.key_id == nil
      assert restored.grantee_uri == nil

      legacy = Map.delete(stored, "grantee_uri")
      assert Capability.from_map(legacy).grantee_uri == nil
    end

    test "a pre-#1399 legacy struct (missing the signature/key_id/grantee_uri keys) serializes without KeyError (#213)" do
      # A durable Kind's `:identity` slice snapshotted before the #1399
      # cap-signing trio (2026-07-14) stores a `%Capability{}` via
      # `term_to_binary`; `binary_to_term` reconstructs it as a struct-shaped
      # map that MATCHES `%Capability{}` (only `:__struct__` is checked) yet
      # LACKS those three keys. `Map.drop/2` on a current struct reproduces
      # that EXACT shape (keeps `:__struct__`, drops the trio).
      legacy_struct =
        Map.drop(
          %Capability{
            kind: :agent,
            behavior: Ezagent.ActionSet.Session,
            action: :send,
            instance: URI.new!("session://team-alpha/default/main"),
            workspace_uri: @ws_default,
            granted_by: @user_uri,
            granted_at: @now
          },
          [:signature, :key_id, :grantee_uri]
        )

      # Pre-fix these three raised `(KeyError) key :signature not found` — the
      # canary cutover-backfill crash (encode_caps → to_map).
      refute Map.has_key?(legacy_struct, :signature)

      stored = Capability.to_map(legacy_struct)
      assert stored["signature"] == nil
      assert stored["key_id"] == nil
      assert stored["grantee_uri"] == nil

      # The direct `Jason.Encoder` (EventLog emit path) must be equally robust.
      assert {:ok, _json} = Jason.encode(legacy_struct)

      restored = stored |> Jason.encode!() |> Jason.decode!() |> Capability.from_map()
      assert restored.signature == nil
      assert restored.key_id == nil
      assert restored.grantee_uri == nil
      # A signature-less legacy cap round-trips as a fully-formed unsigned cap.
      assert restored.kind == :agent
      assert restored.workspace_uri == @ws_default
    end

    test "raw signature, key id, and grantee URI round-trip through caps_json fields" do
      signature = :binary.copy(<<0, 255, 128, 1>>, 16)
      key_id = "v1|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh"
      grantee_uri = Ezagent.URI.new!("entity://team-alpha/user/bob")

      original =
        struct(Capability, %{
          kind: :user,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: :any,
          workspace_uri: @ws_default,
          granted_by: @user_uri,
          granted_at: @now,
          signature: signature,
          key_id: key_id,
          grantee_uri: grantee_uri
        })

      stored = Capability.to_map(original)

      assert stored["signature"] == Base.url_encode64(signature, padding: false)
      assert stored["key_id"] == key_id
      assert stored["grantee_uri"] == URI.to_string(grantee_uri)

      restored = stored |> Jason.encode!() |> Jason.decode!() |> Capability.from_map()

      assert restored == original
      assert restored.signature == signature
      assert restored.key_id == key_id
      assert restored.grantee_uri == grantee_uri
    end

    test "explicit Jason encoder uses the same signing and grantee field wire representation" do
      signature = :binary.copy(<<255, 0>>, 32)
      key_id = "v2|YToq"
      grantee_uri = Ezagent.URI.new!("entity://team-alpha/user/bob")

      cap =
        struct(Capability, %{
          kind: :any,
          behavior: :any,
          action: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: @user_uri,
          granted_at: @now,
          signature: signature,
          key_id: key_id,
          grantee_uri: grantee_uri
        })

      decoded = cap |> Jason.encode!() |> Jason.decode!()

      assert decoded["signature"] == Base.url_encode64(signature, padding: false)
      assert decoded["key_id"] == key_id
      assert decoded["grantee_uri"] == URI.to_string(grantee_uri)

      decoded_nil_grantee = %{cap | grantee_uri: nil} |> Jason.encode!() |> Jason.decode!()
      assert decoded_nil_grantee["grantee_uri"] == nil
    end

    test "from_map rejects a malformed encoded signature" do
      stored =
        Capability.to_map(%Capability{
          kind: :user,
          behavior: :any,
          action: :any,
          instance: :any,
          workspace_uri: @ws_default,
          granted_by: @user_uri,
          granted_at: @now
        })

      assert_raise ArgumentError, ~r/invalid base64url signature/, fn ->
        Capability.from_map(Map.put(stored, "signature", "not+base64url"))
      end
    end
  end

  # Remediation SPEC 2026-05-30 C-C regression: a %Capability{} MUST be
  # JSON-encodable so the `{:emit, :cap_granted, %{cap: cap}}` effect persists
  # to EventLog. Before the encoder, this raised `Jason.EncodeError` /
  # `Protocol.UndefinedError` and Kind.Runtime swallowed it ("continuing") —
  # silently dropping every cap-grant/revoke audit event.
  describe "Jason.Encoder (EventLog emit integrity)" do
    test "encodes a Capability with URI fields, atoms and DateTime without raising" do
      cap = %Capability{
        kind: :user,
        behavior: Ezagent.ActionSet.Session,
        action: :send,
        instance: :any,
        workspace_uri: @ws_default,
        granted_by: @system_uri,
        granted_at: @now
      }

      json = Jason.encode!(cap)
      decoded = Jason.decode!(json)

      assert decoded["kind"] == "user"
      assert decoded["action"] == "send"
      # URI fields stringify; :any atoms pass through.
      assert decoded["granted_by"] == URI.to_string(@system_uri)
      assert decoded["workspace_uri"] == URI.to_string(@ws_default)
      assert decoded["instance"] == "any"
    end

    test "encodes a Capability nested in an emit-style payload map" do
      cap = %Capability{
        kind: :user,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @system_uri,
        granted_at: @now
      }

      payload = %{target_uri: "entity://team-alpha/user/alice", cap: cap, at: @now}
      assert {:ok, _json} = Jason.encode(payload)
    end
  end
end
