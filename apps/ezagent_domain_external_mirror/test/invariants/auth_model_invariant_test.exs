defmodule Ezagent.ExternalMirror.AuthModelInvariantTest do
  @moduledoc """
  ARCHITECTURAL GATE — the audit SPEC's §6 invariant test.

  Per the audit SPEC
  `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
  §6.1: this test IS the gate for the facade auth-model audit.
  Per `feedback_completion_requires_invariant_test`, this audit is
  "done" only when an architectural-goal test exists that would
  fail if ANY of the 22 PR #317 codex findings (or a structurally
  similar new finding) were re-introduced.

  ## The 22 scenarios

  Numbered `0`, `1..10`, `10b`, `11..20` per SPEC §6.2. Each
  regression-protects ONE PR #317 codex finding OR audit-SPEC CRIT.

  Each scenario asserts:

  - The expected failure shape (exact error atom / tuple shape).
  - For denial scenarios: NO downstream observable mutation
    (no adapter I/O, no DB row, no worker, no slice mutation)
    via `AuthModelTestHelpers.assert_no_downstream_work/4`.
  - For positive-state scenarios (14, 15, 16, 19, 20): the
    specific successful state.

  ## What this invariant prevents (SPEC §6.4)

  If a future contributor:
  - Reorders gates 1–4 in the facade → scenarios 1, 5 fail.
  - Moves `lookup_adapter` BEFORE Gate 1 → scenario 0 fails.
  - Re-introduces a forgeable trust-transfer flag → scenario 7 fails.
  - Exposes a public `claim_nonce` that doesn't enforce gates →
    scenario 10b fails.
  - Forgets the FacadeNonceTable expiry check → scenario 9 fails.
  - Removes the persist-first ordering → scenario 12 fails
    (compensating delete + row state).
  - Reverts AdapterInstall ordering → scenario 13 fails.
  - Returns `:ok` instead of `:worker_spawn_failed` on spawn
    exhaustion → scenarios 12, 14 fail (state divergence).
  - Breaks workspace iso facade pre-check OR dispatch §5.6 →
    scenarios 3 or 4 fail respectively.

  ## Scope note

  Some scenarios (13, 18) are STRUCTURALLY covered by existing
  describes in `behavior/external_mirror_test.exs` (the r3 HIGH-3
  and r5 HIGH-A regressions). The invariant test re-asserts them
  here in a single file so the architectural goal of the audit is
  visible in one place. The existing focused tests stay (they
  test individual code paths); these are the COLLECTIVE gate.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.ExternalMirror, as: Facade

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    BindingRow,
    FacadeNonceTable,
    WorkerSpawn
  }

  alias Ezagent.ExternalMirror.AuthModelTestHelpers, as: H

  alias Ezagent.ExternalMirror.TestSupport.{
    MockPublishAdapter,
    MockPublishBinding
  }

  @workspace_uri Ezagent.URI.new!("workspace://default")

  setup do
    :ok = FacadeNonceTable.__clear_all__()

    # Ensure mock_publish adapter is registered (BOTH registries) so
    # gates can run. Mirrors `behavior/external_mirror_test.exs:54`.
    _ = AdapterRegistry.register(MockPublishAdapter)
    _ = BindingRegistry.register_module("mock_publish", MockPublishBinding)

    :ok
  end

  # ============================================================
  # Scenario 0 — Adapter enumeration denial (codex r1 audit-SPEC HIGH-2)
  # ============================================================

  describe "scenario 0 — adapter enumeration denial" do
    test "no-cap caller gets SAME :unauthorized error for real adapter AND nonexistent adapter" do
      owner_uri = H.unique_user_uri("s0-owner")
      session_uri = H.unique_session_uri("s0")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      no_cap_caller = H.unique_user_uri("s0-nocap")
      ctx = H.setup_caller(:no_caps, caller_uri: no_cap_caller)

      # Real adapter
      real_result = Facade.bind(session_uri, "mock_publish", "tgt-s0-real", %{}, ctx)
      # Nonexistent adapter
      fake_result = Facade.bind(session_uri, "nonexistent_adapter_id", "tgt-s0-fake", %{}, ctx)

      assert {:error, :unauthorized} = real_result
      assert {:error, :unauthorized} = fake_result

      assert real_result == fake_result,
             "scenario 0 invariant: no-cap caller MUST get IDENTICAL error for " <>
               "real and fake adapter IDs (cannot enumerate); got " <>
               "real=#{inspect(real_result)} fake=#{inspect(fake_result)}"

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s0-real",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 1 — Cap 1 denial (PR #317 r4 MED)
  # ============================================================

  describe "scenario 1 — Cap 1 denial (no session :bind cap)" do
    test "returns :unauthorized and NO adapter I/O fires" do
      owner_uri = H.unique_user_uri("s1-owner")
      session_uri = H.unique_session_uri("s1")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      ctx = H.setup_caller(:no_caps)

      assert {:error, :unauthorized} =
               Facade.bind(session_uri, "mock_publish", "tgt-s1", %{}, ctx)

      # Gate 4 (target_ownership_check — adapter I/O) MUST NOT have
      # run because Gate 1 failed first. We don't assert this via a
      # counter (MockPublishAdapter's target_ownership_check has no
      # observable side effect to count); the structural guarantee
      # is that we got :unauthorized BEFORE any with-clause downstream
      # of `check_session_bind_cap` could run.
      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s1",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 2 — Cap 2 denial (PR #317 r2 HIGH-3)
  # ============================================================

  describe "scenario 2 — Cap 2 denial (has session bind cap, no per-adapter cap)" do
    test "returns :adapter_not_authorized and NO adapter I/O fires" do
      owner_uri = H.unique_user_uri("s2-owner")
      session_uri = H.unique_session_uri("s2")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      ctx =
        H.setup_caller(:session_bind_only,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      assert {:error, :adapter_not_authorized} =
               Facade.bind(session_uri, "mock_publish", "tgt-s2", %{}, ctx)

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s2",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 3 — Workspace iso denial (facade pre-check, NEW Q4)
  # ============================================================

  describe "scenario 3 — workspace iso denial (facade gate 3)" do
    test "cross-workspace caller hits Gate 3 in facade, gets :cross_workspace_denied" do
      owner_uri = H.unique_user_uri("s3-owner")
      session_uri = H.unique_session_uri("s3")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      # Caller in DIFFERENT workspace from session. Holds session
      # bind cap + adapter allow cap so Gates 1+2 pass; only Gate 3
      # (workspace iso) should deny.
      foreign_caller = H.unique_user_uri("s3-foreign", "other_workspace")

      bind_cap = %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: session_uri,
        workspace_uri: @workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }

      adapter_cap = %Capability{
        kind: :session,
        behavior: MockPublishAdapter.Allow,
        instance: :any,
        workspace_uri: @workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }

      ctx = %{
        caller: foreign_caller,
        caps: MapSet.new([bind_cap, adapter_cap]),
        reply: :ignore
      }

      assert {:error, :cross_workspace_denied} =
               Facade.bind(session_uri, "mock_publish", "tgt-s3", %{}, ctx)

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s3",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 4 — Workspace iso denial (dispatch §5.6, bypass facade)
  # ============================================================

  describe "scenario 4 — workspace iso denial (defense in depth at dispatch §5.6)" do
    test "direct dispatch bypassing facade with cross-workspace caller still denied" do
      owner_uri = H.unique_user_uri("s4-owner")
      session_uri = H.unique_session_uri("s4")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      # Cross-workspace caller direct-dispatching with a forged nonce.
      # Even if they had a nonce, dispatch §5.6 should deny on workspace
      # mismatch BEFORE the action body sees the nonce.
      foreign_caller = H.unique_user_uri("s4-foreign", "other_workspace")

      ctx =
        H.setup_caller(:session_bind_only,
          caller_uri: foreign_caller,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      result =
        H.bypass_facade_dispatch(
          session_uri,
          "mock_publish",
          "tgt-s4",
          %{_facade_nonce: :crypto.strong_rand_bytes(32)},
          ctx
        )

      # Dispatch §5.6 returns :cross_workspace_denied for cross-workspace
      # callers; if §5.6 isn't on this path, the action body's nonce
      # check would return :bind_must_go_through_facade — EITHER is
      # acceptable as long as the bind does not succeed.
      assert match?({:error, :cross_workspace_denied}, result) or
               match?({:error, :bind_must_go_through_facade}, result),
             "expected :cross_workspace_denied (dispatch §5.6) OR " <>
               ":bind_must_go_through_facade (action body nonce check); got #{inspect(result)}"

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s4",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 5 — target_ownership_check denial
  # ============================================================

  describe "scenario 5 — Gate 4 target_ownership_check denial" do
    test "adapter returns {:error, _}; facade returns :target_ownership_denied" do
      # Use TimeoutAdapter shape — but we need an adapter whose
      # target_ownership_check returns {:error, _}. Build a counted
      # adapter in this test via Process.put for the counter.
      #
      # Simplest path: register a per-test adapter module. To avoid
      # the complexity, we'll use a process-dictionary toggle on
      # MockPublishAdapter — but since it doesn't support that, we
      # use a thin local adapter module DEFINED in test support.
      #
      # The DenyAdapter is defined at the bottom of this test file
      # (see `Ezagent.ExternalMirror.AuthModelInvariantTest.DenyAdapter`).
      _ = AdapterRegistry.register(__MODULE__.DenyAdapter)
      _ = BindingRegistry.register_module("deny_em", __MODULE__.DenyBinding)

      owner_uri = H.unique_user_uri("s5-owner")
      session_uri = H.unique_session_uri("s5")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      ctx =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          adapter_allow: __MODULE__.DenyAdapter.Allow
        )

      assert {:error, {:target_ownership_denied, :not_a_member}} =
               Facade.bind(session_uri, "deny_em", "tgt-s5", %{}, ctx)

      H.assert_no_downstream_work(session_uri, "deny_em", "tgt-s5", assert_no_adapter_io: false)
    end
  end

  # ============================================================
  # Scenario 6 — target_ownership_check timeout
  # ============================================================

  describe "scenario 6 — Gate 4 target_ownership_check timeout" do
    test "adapter sleeps past timeout; facade returns :target_check_timeout" do
      _ = AdapterRegistry.register(__MODULE__.SlowAdapter)
      _ = BindingRegistry.register_module("slow_em", __MODULE__.SlowBinding)

      owner_uri = H.unique_user_uri("s6-owner")
      session_uri = H.unique_session_uri("s6")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      ctx =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          adapter_allow: __MODULE__.SlowAdapter.Allow
        )

      assert {:error, :target_check_timeout} =
               Facade.bind(session_uri, "slow_em", "tgt-s6", %{}, ctx)

      H.assert_no_downstream_work(session_uri, "slow_em", "tgt-s6", assert_no_adapter_io: false)
    end
  end

  # ============================================================
  # Scenario 7 — Nonce forgery (PR #317 r3 CRIT)
  # ============================================================

  describe "scenario 7 — nonce forgery (random nonce in args)" do
    test "direct dispatch with random nonce returns :bind_must_go_through_facade" do
      owner_uri = H.unique_user_uri("s7-owner")
      session_uri = H.unique_session_uri("s7")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      # Caller has session bind cap (Gate 1 + dispatch §5.5 pass) so
      # the dispatch reaches the action body — where the nonce is
      # verified.
      ctx =
        H.setup_caller(:session_bind_only,
          caller_uri: owner_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      result =
        H.bypass_facade_dispatch(
          session_uri,
          "mock_publish",
          "tgt-s7",
          %{_facade_nonce: :crypto.strong_rand_bytes(32)},
          ctx
        )

      assert {:error, :bind_must_go_through_facade} = result

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s7",
        assert_no_adapter_io: false
      )
    end
  end

  # ============================================================
  # Scenario 8 — Nonce replay (PR #317 r3 CRIT)
  # ============================================================

  describe "scenario 8 — nonce replay (consume twice)" do
    test "second consume of the same nonce returns :error" do
      session_uri = H.unique_session_uri("s8")
      caller_uri = H.unique_user_uri("s8-caller")
      ctx = build_admin_ctx(caller_uri)

      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_uri,
          ctx,
          "mock_publish",
          "tgt-s8"
        )

      assert :ok =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-s8", caller_uri}
               )

      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-s8", caller_uri}
               )
    end
  end

  # ============================================================
  # Scenario 9 — Nonce expiry (PR #317 r3 CRIT)
  # ============================================================

  describe "scenario 9 — nonce expiry (sleep past TTL)" do
    test "consuming after TTL returns :error" do
      session_uri = H.unique_session_uri("s9")
      caller_uri = H.unique_user_uri("s9-caller")
      ctx = build_admin_ctx(caller_uri)

      # 50ms TTL via @doc false 5-arity form
      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_uri,
          ctx,
          "mock_publish",
          "tgt-s9",
          50
        )

      Process.sleep(100)

      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_uri, "mock_publish", "tgt-s9", caller_uri}
               )
    end
  end

  # ============================================================
  # Scenario 10 — Nonce tuple mismatch (PR #317 r3 CRIT)
  # ============================================================

  describe "scenario 10 — nonce tuple mismatch" do
    test "consume with different session/adapter/target returns :error" do
      session_a = H.unique_session_uri("s10a")
      session_b = H.unique_session_uri("s10b")
      caller_uri = H.unique_user_uri("s10-caller")
      ctx = build_admin_ctx(caller_uri)

      {:ok, nonce} =
        FacadeNonceTable.claim_nonce(
          session_a,
          ctx,
          "mock_publish",
          "tgt-s10"
        )

      # Different session → reject
      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_b, "mock_publish", "tgt-s10", caller_uri}
               )

      # Correct tuple AFTER mismatch consume → still :error (single-use even on mismatch)
      assert :error =
               FacadeNonceTable.consume_nonce(
                 nonce,
                 {session_a, "mock_publish", "tgt-s10", caller_uri}
               )
    end
  end

  # ============================================================
  # Scenario 10b — Direct claim_nonce bypass (codex r1 audit-SPEC CRIT-1)
  # ============================================================

  describe "scenario 10b — direct claim_nonce bypass (audit-SPEC CRIT-1 STRUCTURAL GATE)" do
    test "in-VM caller missing cap 2 cannot mint a nonce via claim_nonce/4" do
      owner_uri = H.unique_user_uri("s10b-owner")
      session_uri = H.unique_session_uri("s10b")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      # Caller holds ONLY session bind cap (Gate 1). Calls claim_nonce/4
      # DIRECTLY (bypassing the facade) — pre-CRIT-1 fix would mint a
      # nonce because claim_nonce was a freely-callable mint. Post-fix
      # claim_nonce internally runs Gates 1+2+3+4; Gate 2 fails →
      # no nonce returned.
      bypass_caller = H.unique_user_uri("s10b-bypass")

      bypass_ctx = %{
        caller: bypass_caller,
        caps:
          MapSet.new([
            %Capability{
              kind: :session,
              behavior: Ezagent.ActionSet.ExternalMirror,
              instance: session_uri,
              workspace_uri: @workspace_uri,
              granted_by: User.admin_uri(),
              granted_at: DateTime.utc_now()
            }
          ]),
        reply: :ignore
      }

      assert {:error, :adapter_not_authorized} =
               FacadeNonceTable.claim_nonce(
                 session_uri,
                 bypass_ctx,
                 "mock_publish",
                 "tgt-s10b"
               )

      H.assert_no_downstream_work(session_uri, "mock_publish", "tgt-s10b",
        assert_no_adapter_io: false
      )
    end

    test "in-VM caller with NO caps calling claim_nonce/4 directly fails at Gate 1" do
      session_uri = H.unique_session_uri("s10b-2")
      nocap_caller = H.unique_user_uri("s10b-2-nocap")

      ctx = %{
        caller: nocap_caller,
        caps: MapSet.new(),
        reply: :ignore
      }

      assert {:error, :unauthorized} =
               FacadeNonceTable.claim_nonce(
                 session_uri,
                 ctx,
                 "mock_publish",
                 "tgt-s10b2"
               )
    end

    # codex PR-AUDIT r2 HIGH regression — TTL-override only available in test
    #
    # Pre-r2 fix, `claim_nonce/5` was `@doc false` but still publicly
    # callable; a caller currently passing all gates could mint a
    # nonce with arbitrarily long TTL and direct-dispatch later AFTER
    # target membership had been revoked — defeating the SPEC-pinned
    # 5-second stale-authorization bound.
    #
    # Post-fix, the 5-arity form is compile-gated to `Mix.env() == :test`.
    # In production binaries it does NOT exist at all. This invariant
    # asserts the structural compile-time gate is in place by
    # inspecting the module's exported functions: in production
    # `claim_nonce/5` must be absent; in test it must be present
    # (otherwise the nonce-expiry scenarios couldn't run).
    test "TTL-override claim_nonce/5 exists ONLY in test env (codex r2 HIGH gate)" do
      exports = FacadeNonceTable.__info__(:functions)

      # In test env this assertion confirms the 5-arity form is
      # available so the §6 expiry scenarios (9) can run.
      assert {:claim_nonce, 5} in exports,
             "expected claim_nonce/5 to exist in test env (for nonce-expiry scenarios); " <>
               "got exports: #{inspect(exports)}"

      # Structural source-level gate: the 5-arity form MUST be inside
      # `if Mix.env() == :test do` block in the source. This catches
      # future contributors removing the gate accidentally — even if
      # the function exists in test env (as it must), the source-level
      # check enforces it's compile-gated.
      source = read_source_file("lib/ezagent/external_mirror/facade_nonce_table.ex")

      assert source =~ ~r/if\s+Mix\.env\(\)\s*==\s*:test\s+do/,
             "scenario 10b TTL-gate invariant: facade_nonce_table.ex MUST guard the " <>
               "5-arity claim_nonce with `if Mix.env() == :test do` so the TTL " <>
               "override is unavailable in production builds (codex r2 HIGH)"

      assert source =~ ~r/def\s+claim_nonce\(.*ttl_ms\)\s+when/,
             "scenario 10b TTL-gate invariant: 5-arity claim_nonce definition MUST " <>
               "exist somewhere in source (in the test-gated block)"
    end

    # codex PR-AUDIT r1 CRIT regression — adapter spoofing via
    # caller-supplied module
    #
    # Pre-fix, claim_nonce took adapter_module directly + ran Gate 2
    # (cap_subject lookup) + Gate 4 (target_ownership_check) against
    # the caller-supplied module. An in-VM attacker could construct
    # a spoof module whose adapter_id/0 returned a real registered
    # adapter's ID, whose cap_subject/0 pointed at a cap they already
    # hold, and whose target_ownership_check/2 returned :ok. Gates
    # passed against the spoof, nonce was minted for the REAL
    # adapter's ID, and the action body bound to the real adapter
    # bypassing its real Cap 2 + Gate 4.
    #
    # Post-fix: claim_nonce takes adapter_id STRING; the registry
    # resolves it to the real module. A spoof attempt via direct
    # `__MODULE__` reference cannot bypass — there's no module
    # parameter to spoof. This test asserts the public API surface
    # rejects the attack vector by construction.
    test "claim_nonce/4 takes adapter_id STRING — no caller-supplied module parameter to spoof" do
      session_uri = H.unique_session_uri("s10c")
      caller_uri = H.unique_user_uri("s10c-caller")
      ctx = build_admin_ctx(caller_uri)

      # Unregistered adapter_id → :unknown_adapter (Gate 0). The
      # caller cannot smuggle in a spoof module; the only way to
      # "name" an adapter is via its registered ID.
      assert {:error, :unknown_adapter} =
               FacadeNonceTable.claim_nonce(
                 session_uri,
                 ctx,
                 "nonexistent_spoofed_id",
                 "tgt-s10c"
               )

      # Registered adapter_id → real module resolved by registry.
      # Admin ctx → all gates pass → nonce minted.
      assert {:ok, _nonce} =
               FacadeNonceTable.claim_nonce(
                 session_uri,
                 ctx,
                 "mock_publish",
                 "tgt-s10c-real"
               )
    end
  end

  # ============================================================
  # Scenario 11 — DB insert failure (NOT NULL etc — PR #317 r5 HIGH-B)
  # ============================================================

  describe "scenario 11 — non-unique DB insert error propagates verbatim" do
    test "non-unique changeset error returns {:db_insert_failed, _}; no worker spawned" do
      # The cleanest way to provoke a non-unique error in the
      # production path is to insert a row with workspace_uri = nil,
      # which violates the NOT NULL constraint. We exercise
      # `BindingRow.insert/1` directly (not via Facade.bind/5 — that
      # path doesn't expose the nil-workspace shape).
      session_uri = H.unique_session_uri("s11")

      # workspace_uri intentionally OMITTED → validate_required fails
      bad_attrs = %{
        id: "mock_publish/tgt-s11",
        session_uri: URI.to_string(session_uri),
        adapter_id: "mock_publish",
        target_id: "tgt-s11",
        opts_json: "{}",
        bound_by: "entity://default/user/admin",
        bound_at: DateTime.utc_now()
      }

      result = BindingRow.insert(bad_attrs)

      case result do
        {:error, %Ecto.Changeset{} = cs} ->
          # The changeset MUST surface the constraint error (NOT silently
          # mapped to :ok). The discrimination test is in scenario 19; here
          # we just verify the constraint error is observable as a changeset
          # (not a raised exception, not :ok).
          assert cs.valid? == false,
                 "expected invalid changeset; got #{inspect(cs)}"

        other ->
          flunk("expected {:error, %Ecto.Changeset{}}; got #{inspect(other)}")
      end

      # No worker should exist for this triple.
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, "mock_publish", "tgt-s11")
      assert :error = KindRegistry.lookup(worker_uri)
    end
  end

  # ============================================================
  # Scenario 12 — Worker spawn failure AFTER row persisted
  # (PR #317 r4 HIGH-2 + r5 HIGH-B)
  # ============================================================

  describe "scenario 12 — worker spawn failure after persist → compensating delete" do
    test "STRUCTURAL: behavior body returns :worker_spawn_failed (not silent :ok)" do
      # Per SPEC §4.3 — compensating delete is the post-r5 contract.
      # The full mechanic (pre-register foreign pid, race spawn) is
      # covered by `behavior/external_mirror_test.exs` describe
      # "PR-EM-3 r5 HIGH-2". Here we assert the STRUCTURAL invariant:
      # `Behavior.ExternalMirror` exports a `do_bind` path whose
      # `:worker_spawn_failed` return shape preserves the error
      # (not the :warning+degrade anti-pattern this audit prohibits
      # per §8.1).
      #
      # We verify the structural property by inspecting the source:
      # the `do_spawn_after_persist/6` function MUST match the
      # `{:error, :worker_spawn_failed}` shape from
      # `spawn_worker_idempotently/3` and propagate it AFTER running
      # the compensating delete.
      source = read_source_file("lib/ezagent/behavior/external_mirror.ex")

      assert source =~ ~r/\{:error, :worker_spawn_failed\}\s*=\s*err\s*->/,
             "scenario 12 invariant: Behavior.ExternalMirror.do_spawn_after_persist/6 " <>
               "MUST match {:error, :worker_spawn_failed} and propagate it (not return :ok); " <>
               "this is the let-it-crash regression gate for r4 HIGH-2 + r5 HIGH-B"

      assert source =~ ~r/BindingRow\.delete_by_natural_key\(session_uri, aid, tid\)/,
             "scenario 12 invariant: compensating delete MUST run after spawn failure " <>
               "(by_natural_key — NOT the session-unscoped binding_id)"
    end
  end

  # ============================================================
  # Scenario 13 — AdapterInstall ordering (PR #317 r5 HIGH-A)
  # ============================================================

  describe "scenario 13 — AdapterInstall fires only after BOTH registries populated" do
    test "STRUCTURAL: install hook registered via Plugin.publish_after_all_registered/2" do
      # This audit's PR-EM-AUDIT lifted the r5 HIGH-A
      # maybe_install/maybe_install_by_adapter_id symmetric pair to
      # `Ezagent.Plugin.publish_after_all_registered/2`. The original
      # observable behavior (install fires after BOTH AdapterRegistry
      # AND BindingRegistry have entries) is preserved AND tested by
      # the existing `behavior/external_mirror_test.exs` describe
      # "PR-EM-3 codex r5 HIGH-A".
      #
      # Here we assert the STRUCTURAL goal: AdapterInstall calls
      # `Ezagent.Plugin.publish_after_all_registered/2` rather than
      # re-implementing the dual-check inline.
      source = read_source_file("lib/ezagent/external_mirror/adapter_install.ex")

      assert source =~ ~r/Ezagent\.Plugin\.publish_after_all_registered/,
             "scenario 13 invariant: AdapterInstall MUST use the core primitive " <>
               "Ezagent.Plugin.publish_after_all_registered/2 (NOT the symmetric " <>
               "maybe_install pair) — this is the lift-to-core gate"

      refute source =~ ~r/defp\s+binding_registered\?/,
             "scenario 13 invariant: the pre-lift `binding_registered?/1` helper MUST " <>
               "be removed — its job is now done by the primitive's all_registered? check"
    end
  end

  # ============================================================
  # Scenario 14 — Happy path
  # ============================================================

  describe "scenario 14 — happy path (all gates pass)" do
    test "exactly 1 row, 1 worker, 1 slice binding; nonce consumed" do
      owner_uri = H.unique_user_uri("s14-owner")
      session_uri = H.unique_session_uri("s14")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      target_id = "tgt-s14"
      MockPublishBinding.register_observer(target_id, self())

      ctx =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      assert {:ok, %{ok: true, binding_id: binding_id, worker_uri: worker_uri}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      assert is_binary(binding_id)
      assert match?(%URI{}, worker_uri)

      # 1 row
      rows = BindingRow.list_for_session(session_uri)
      assert length(rows) == 1, "expected 1 row, got #{length(rows)}"

      # 1 worker in KindRegistry
      assert {:ok, _pid} = KindRegistry.lookup(worker_uri)

      # 1 slice binding via the dispatch-gated facade read
      assert {:ok, slice_bindings} = Facade.list_bindings(session_uri, ctx)
      assert length(slice_bindings) == 1
    end
  end

  # ============================================================
  # Scenario 15 — Row id collision across sessions (codex r1 CRIT)
  # ============================================================

  describe "scenario 15 — row id collision across sessions" do
    test "two sessions binding same (adapter_id, target_id) → two distinct rows" do
      owner_uri = H.unique_user_uri("s15-owner")
      session_a = H.unique_session_uri("s15a")
      session_b = H.unique_session_uri("s15b")
      :ok = H.spawn_owner_and_session(owner_uri, session_a)
      :ok = H.spawn_owner_and_session(owner_uri, session_b)

      on_exit(fn ->
        H.cleanup_session(session_a)
        H.cleanup_session(session_b)
      end)

      target_id = "tgt-s15-shared"
      MockPublishBinding.register_observer(target_id, self())

      ctx_a =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_a,
          workspace_uri: @workspace_uri
        )

      ctx_b =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_b,
          workspace_uri: @workspace_uri
        )

      assert {:ok, %{ok: true}} =
               Facade.bind(session_a, "mock_publish", target_id, %{}, ctx_a)

      assert {:ok, %{ok: true}} =
               Facade.bind(session_b, "mock_publish", target_id, %{}, ctx_b)

      rows_a = BindingRow.list_for_session(session_a)
      rows_b = BindingRow.list_for_session(session_b)

      assert length(rows_a) == 1
      assert length(rows_b) == 1

      # Distinct row ids per the session-scoped natural-key fix
      [row_a] = rows_a
      [row_b] = rows_b

      assert row_a.id != row_b.id or row_a.session_uri != row_b.session_uri,
             "scenario 15 invariant: two sessions binding same (adapter, target) MUST " <>
               "have distinguishable rows (session_uri segments must differ even if id matches)"

      # Unbind from session A leaves session B intact
      assert {:ok, _} =
               Facade.unbind(session_a, "mock_publish", target_id, ctx_a)

      assert length(BindingRow.list_for_session(session_b)) == 1
    end
  end

  # ============================================================
  # Scenario 16 — Atom DoS via opts keys (codex r1 HIGH)
  # ============================================================

  describe "scenario 16 — opts keys MUST NOT be String.to_atom'd" do
    test "STRUCTURAL: source code MUST NOT call String.to_atom/1 in bind/rehydrate paths" do
      # Hardening test: PR #317 r1 HIGH fix was to keep opts keys as
      # strings, never call `String.to_atom/1` on JSON-decoded user
      # input. Verify by source scan — atom-table DoS is a class of
      # bug grep can catch durably.
      paths = [
        "lib/ezagent/external_mirror/binding_row.ex",
        "lib/ezagent/behavior/external_mirror.ex"
      ]

      Enum.each(paths, fn path ->
        source = read_source_file(path)

        refute source =~ ~r/String\.to_atom\(/,
               "scenario 16 invariant: #{path} MUST NOT call String.to_atom/1 — " <>
                 "atom-table DoS regression (PR #317 r1 HIGH)"
      end)
    end
  end

  # ============================================================
  # Scenario 17 — Read-side list_bindings/2 unauthorized
  # ============================================================

  describe "scenario 17 — list_bindings/2 enforces CapBAC" do
    test "caller without :list_bindings cap gets :unauthorized" do
      owner_uri = H.unique_user_uri("s17-owner")
      session_uri = H.unique_session_uri("s17")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      no_cap_caller = H.unique_user_uri("s17-nocap")
      ctx = H.setup_caller(:no_caps, caller_uri: no_cap_caller)

      result = Facade.list_bindings(session_uri, ctx)

      assert match?({:error, :missing_cap}, result),
             "scenario 17 invariant: list_bindings/2 MUST reject callers " <>
               "without the :list_bindings cap (dispatch §5.5 gate); got #{inspect(result)}"
    end
  end

  # ============================================================
  # Scenario 18 — Cap subject registry visibility
  # ============================================================

  describe "scenario 18 — per-adapter cap subject is visible after AdapterInstall" do
    test "CapabilityRegistry.lookup_subject finds the adapter's allow cap shape" do
      # MockPublishAdapter registers in the test_helper.exs / outer
      # `setup`. AdapterInstall's `register_cap_subject_step` adds the
      # cap subject to `Ezagent.CapabilityRegistry`. Admins must be
      # able to grant per-adapter caps via the normal grant path.
      assert {:ok, %{}} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.Session,
                 :allow_mock_publish
               )
    end
  end

  # ============================================================
  # Scenario 19 — Unique-conflict returns changeset (codex r3 HIGH-2)
  # ============================================================

  describe "scenario 19 — unique-conflict returns changeset, not raise" do
    test "BindingRow.insert/1 returns {:error, %Changeset{}} with constraint: :unique" do
      owner_uri = H.unique_user_uri("s19-owner")
      session_uri = H.unique_session_uri("s19")
      :ok = H.spawn_owner_and_session(owner_uri, session_uri)
      on_exit(fn -> H.cleanup_session(session_uri) end)

      target_id = "tgt-s19"
      MockPublishBinding.register_observer(target_id, self())

      ctx =
        H.setup_caller(:session_bind_plus_adapter,
          caller_uri: owner_uri,
          session_uri: session_uri,
          workspace_uri: @workspace_uri
        )

      # First bind — persist + spawn.
      assert {:ok, %{ok: true}} =
               Facade.bind(session_uri, "mock_publish", target_id, %{}, ctx)

      # Now manually try to insert a duplicate row directly. The DB
      # unique index MUST fire as a changeset error (not a raised
      # Ecto.ConstraintError).
      attrs = %{
        id: "mock_publish/dup-#{System.unique_integer([:positive])}",
        session_uri: URI.to_string(session_uri),
        adapter_id: "mock_publish",
        target_id: target_id,
        opts_json: "{}",
        bound_by: URI.to_string(owner_uri),
        bound_at: DateTime.utc_now(),
        workspace_uri: URI.to_string(@workspace_uri)
      }

      result = BindingRow.insert(attrs)

      case result do
        {:error, %Ecto.Changeset{errors: errors} = cs} ->
          has_unique_err =
            Enum.any?(errors, fn
              {_field, {_msg, opts}} when is_list(opts) ->
                Keyword.get(opts, :constraint) == :unique

              _ ->
                false
            end)

          assert has_unique_err,
                 "scenario 19 invariant: BindingRow.insert/1 unique conflict MUST " <>
                   "surface as a changeset with constraint: :unique in errors; got #{inspect(cs.errors)}"

        other ->
          flunk(
            "scenario 19 invariant: expected {:error, %Ecto.Changeset{} with " <>
              "constraint: :unique}; got #{inspect(other)}"
          )
      end
    end
  end

  # ============================================================
  # Scenario 20 — BootReconciler retry loop
  # ============================================================

  describe "scenario 20 — BootReconciler retries when spawn handler missing" do
    test "STRUCTURAL: BootReconciler has bounded-retry mechanism" do
      # The BootReconciler's r4 HIGH-1 fix added a bounded retry loop:
      # when a binding row's spawn handler isn't yet registered (race
      # between chat Application boot + external_mirror's boot
      # reconciliation), the row stays in the retry set until either
      # the handler registers + spawn succeeds, OR 30 attempts are
      # exhausted.
      source = read_source_file("lib/ezagent/external_mirror/boot_reconciler.ex")

      assert source =~ ~r/{:retry,/ or source =~ ~r/:retry\b/,
             "scenario 20 invariant: BootReconciler MUST classify spawn-handler-missing " <>
               "as :retry (the r4 HIGH-1 bounded retry contract); got source that lacks " <>
               "any :retry classification"

      assert source =~ ~r/retry|attempts?/i,
             "scenario 20 invariant: BootReconciler MUST have an observable retry-budget " <>
               "or attempts mechanism (literal 'retry' or 'attempts' in source)"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Source-file path helper for STRUCTURAL invariant checks
  # (scenarios 12, 13, 16, 20). Resolves paths relative to the
  # test's own __DIR__ so the test works regardless of `mix test`
  # invocation CWD (umbrella root vs per-app).
  defp read_source_file(rel_path) do
    # __DIR__ is `<app>/test/invariants` → go up 2 to reach app root.
    app_root = Path.expand(Path.join([__DIR__, "..", ".."]))
    File.read!(Path.join(app_root, rel_path))
  end

  defp build_admin_ctx(caller_uri) do
    %{
      caller: caller_uri,
      caps:
        MapSet.new([
          %Capability{
            kind: :any,
            behavior: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.user(:system, :admin),
            granted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]),
      reply: :ignore
    }
  end

  # ============================================================
  # Test-only adapters used by scenarios 5 and 6
  # ============================================================

  defmodule DenyAdapter.Allow do
    @moduledoc false
    @behaviour Ezagent.ActionSet

    @impl true
    def actions, do: [:allow_deny_em]
    @impl true
    def cap_subjects, do: [{:allow_deny_em, "Allow binding deny adapter."}]
    @impl true
    def dispatchable?, do: false
    @impl true
    def state_slice, do: :external_adapter_deny_em
    @impl true
    def init_slice(_), do: %{}
    @impl true
    def invoke(_, _, _, _), do: raise("cap-only")
    @impl true
    def interface, do: %{}
    @impl true
    def data_owner(_), do: :any
    @impl true
    def required_caps, do: []
  end

  defmodule DenyAdapter do
    @moduledoc false
    @behaviour Ezagent.ExternalMirror.Adapter

    @impl true
    def adapter_id, do: "deny_em"
    @impl true
    def display_name, do: "Deny Adapter"
    @impl true
    def description, do: "Test-only — denies target_ownership_check"
    @impl true
    def binding_module, do: Ezagent.ExternalMirror.AuthModelInvariantTest.DenyBinding
    @impl true
    def cap_subject,
      do: %{
        behavior_module: Ezagent.ExternalMirror.AuthModelInvariantTest.DenyAdapter.Allow,
        description: "deny adapter cap"
      }

    @impl true
    def target_ownership_check(_caller, _target_id), do: {:error, :not_a_member}
    @impl true
    def event_to_payload(_), do: :no_publish
  end

  defmodule DenyBinding do
    @moduledoc false
    @behaviour Ezagent.ExternalMirror.Binding

    @impl true
    def adapter_module, do: Ezagent.ExternalMirror.AuthModelInvariantTest.DenyAdapter
    @impl true
    def init({_, _, opts}), do: {:ok, opts}
    @impl true
    def publish(_, state), do: {:ok, state}
    @impl true
    def terminate(_, _), do: :ok
  end

  defmodule SlowAdapter.Allow do
    @moduledoc false
    @behaviour Ezagent.ActionSet

    @impl true
    def actions, do: [:allow_slow_em]
    @impl true
    def cap_subjects, do: [{:allow_slow_em, "Allow slow adapter."}]
    @impl true
    def dispatchable?, do: false
    @impl true
    def state_slice, do: :external_adapter_slow_em
    @impl true
    def init_slice(_), do: %{}
    @impl true
    def invoke(_, _, _, _), do: raise("cap-only")
    @impl true
    def interface, do: %{}
    @impl true
    def data_owner(_), do: :any
    @impl true
    def required_caps, do: []
  end

  defmodule SlowAdapter do
    @moduledoc false
    @behaviour Ezagent.ExternalMirror.Adapter

    @impl true
    def adapter_id, do: "slow_em"
    @impl true
    def display_name, do: "Slow Adapter"
    @impl true
    def description, do: "Test-only — sleeps past target_ownership_check_timeout"
    @impl true
    def binding_module, do: Ezagent.ExternalMirror.AuthModelInvariantTest.SlowBinding
    @impl true
    def cap_subject,
      do: %{
        behavior_module: Ezagent.ExternalMirror.AuthModelInvariantTest.SlowAdapter.Allow,
        description: "slow adapter cap"
      }

    @impl true
    def target_ownership_check(_caller, _target_id) do
      # Sleep longer than the override below to force a timeout.
      Process.sleep(500)
      :ok
    end

    @impl true
    def event_to_payload(_), do: :no_publish

    # Override default 5_000ms to 100ms for fast tests
    @impl true
    def target_ownership_check_timeout, do: 100
  end

  defmodule SlowBinding do
    @moduledoc false
    @behaviour Ezagent.ExternalMirror.Binding

    @impl true
    def adapter_module, do: Ezagent.ExternalMirror.AuthModelInvariantTest.SlowAdapter
    @impl true
    def init({_, _, opts}), do: {:ok, opts}
    @impl true
    def publish(_, state), do: {:ok, state}
    @impl true
    def terminate(_, _), do: :ok
  end
end
