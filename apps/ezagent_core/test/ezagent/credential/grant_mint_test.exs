defmodule Ezagent.Credential.GrantMintTest do
  @moduledoc """
  #201-cred — regression tests for codex re-review findings 2, 3 (row level),
  4 and 5 on the credential-grant path:

    * F2 (HIGH) — compensation is CONFIRMED, never best-effort: a failing
      `delete_incarnation` is retried and a persistent failure propagates as
      `{:error, :grant_compensation_failed}` (pre-fix `Cascade.compensate_grant/2`
      rescued to `:ok`, silently leaving the grant durable).
    * F3 (HIGH) — `GrantRow.insert/1` mints the `incarnation_id`
      UNCONDITIONALLY (a caller-supplied id is overwritten).
    * F4 (HIGH) — materialization revalidates `(agent_uri, incarnation_id,
      version)`: a delete+reinsert at the SAME version (or two reapprovals
      racing one version number) can no longer pass a stale materializer.
      Reapproval advances the version ATOMICALLY.
    * F5 (HIGH) — the authorizing holder/source authority generations are
      recorded at authorization, re-validated under lock at insertion (a
      regenesis in between rejects the stale mint) and again at every
      materialization fetch.

  Each test in this file fails on the pre-#201-cred branch tip.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  alias Ezagent.Credential.{GrantMint, GrantRow, Resolver}
  alias Ezagent.Kind.CreatedWitness

  defp uniq, do: System.unique_integer([:positive])

  # #201-cred (codex r2 NEW-HIGH-3) — the structural created-winner witness a
  # genuine `:started ∧ created?` spawn would mint. Tests that exercise a
  # LEGITIMATE mint pass one bound to the agent under mint.
  defp witness(%URI{} = agent_uri), do: CreatedWitness.new(agent_uri)

  defp grant_attrs(agent_name) do
    source = "entity://team-a/agent/src-#{uniq()}"

    %{
      agent_uri: "entity://team-a/agent/#{agent_name}-#{uniq()}",
      credential_source_uri: source,
      approved_by: "entity://team-a/user/alice",
      approved_scope: source,
      version: 1
    }
  end

  defp seed_source(uri_str) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri_str
  end

  describe "F2 — confirmed compensation" do
    test "compensate retries a failing delete until the incarnation is confirmed absent" do
      attrs = grant_attrs("comp-retry")
      {:ok, g} = GrantRow.insert(attrs)

      attempts = :counters.new(1, [])

      delete_fun = fn uri, inc ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) < 3 do
          {:error, :forced_db_failure}
        else
          GrantRow.delete_incarnation(uri, inc)
        end
      end

      assert :ok =
               GrantMint.compensate(g.agent_uri, g.incarnation_id,
                 delete_fun: delete_fun,
                 backoff_ms: 1
               )

      assert :counters.get(attempts, 1) == 3
      assert GrantRow.get_for_agent(g.agent_uri) == nil
    end

    test "compensate failure PROPAGATES — never rescued-to-:ok (no silent leak)" do
      attrs = grant_attrs("comp-fail")
      {:ok, g} = GrantRow.insert(attrs)

      delete_fun = fn _uri, _inc -> {:error, :forced_db_failure} end

      # On the pre-fix branch tip the compensator rescued the failure and
      # returned `:ok` — the caller believed the cleanup succeeded while the
      # grant stayed durable. Now the failure is surfaced...
      assert {:error, :grant_compensation_failed} =
               GrantMint.compensate(g.agent_uri, g.incarnation_id,
                 delete_fun: delete_fun,
                 attempts: 2,
                 backoff_ms: 1
               )

      # ...and the leak is LOUD: the row is still there for an operator (or a
      # retrying caller) to see — not hidden behind a fake `:ok`.
      assert GrantRow.get_for_agent(g.agent_uri) != nil

      assert {:ok, :deleted} = GrantRow.delete_incarnation(g.agent_uri, g.incarnation_id)
    end
  end

  # #201-cred (codex r3 NEW-HIGH-1) — the shared on-RAISE boundary. `compensate/3`
  # already surfaces an exhausted compensation as `{:error,
  # :grant_compensation_failed}` (F2 above); the pre-r3 raise sites then `_ =`
  # -discarded that result and re-raised ONLY the original — a silent durable leak.
  # `reraise_compensating/5` + `raise_compensating/6` now propagate the failure.
  describe "NEW-HIGH-1 — post-mint raise propagates compensation failure (never discarded)" do
    test "reraise_compensating re-raises the ORIGINAL and DELETES the minted grant on success" do
      attrs = grant_attrs("reraise-ok")
      {:ok, g} = GrantRow.insert(attrs)

      assert_raise RuntimeError, "boom-after-mint", fn ->
        try do
          raise "boom-after-mint"
        rescue
          e -> GrantMint.reraise_compensating(g.agent_uri, g.incarnation_id, e, __STACKTRACE__)
        end
      end

      # the minted grant was CONFIRM-compensated; the original propagated unchanged.
      assert GrantRow.get_for_agent(g.agent_uri) == nil
    end

    test "reraise_compensating SURFACES an exhausted compensation as GrantCompensationLeaked" do
      attrs = grant_attrs("reraise-leak")
      {:ok, g} = GrantRow.insert(attrs)
      failing = fn _uri, _inc -> {:error, :forced_db_failure} end

      # Pre-fix: the raise path did `_ = compensate(...); reraise original`, so an
      # exhausted compensation was DISCARDED and the ORIGINAL propagated while the
      # grant leaked silently. Now the abort CARRIES the leak.
      err =
        assert_raise Ezagent.Credential.GrantCompensationLeaked, fn ->
          try do
            raise "boom-after-mint"
          rescue
            e ->
              GrantMint.reraise_compensating(g.agent_uri, g.incarnation_id, e, __STACKTRACE__,
                delete_fun: failing,
                attempts: 2,
                backoff_ms: 1
              )
          end
        end

      assert err.agent_uri == g.agent_uri
      assert err.incarnation_id == g.incarnation_id
      assert %RuntimeError{message: "boom-after-mint"} = err.original
      # the delete genuinely failed → the row remains, but the abort SURFACED it.
      assert GrantRow.get_for_agent(g.agent_uri) != nil

      assert {:ok, :deleted} = GrantRow.delete_incarnation(g.agent_uri, g.incarnation_id)
    end

    test "reraise_compensating with a nil minted incarnation re-raises the ORIGINAL untouched" do
      # A no-pending winner minted nothing (r3 MEDIUM-5) — nothing to compensate,
      # so the original exception propagates UNWRAPPED (never GrantCompensationLeaked).
      agent = "entity://team-a/agent/reraise-nil-#{uniq()}"

      assert_raise RuntimeError, "boom", fn ->
        try do
          raise "boom"
        rescue
          e -> GrantMint.reraise_compensating(agent, nil, e, __STACKTRACE__)
        end
      end
    end

    test "raise_compensating re-raises a THROW after compensating; surfaces exhaustion" do
      {:ok, g} = GrantRow.insert(grant_attrs("throw-ok"))

      thrown =
        catch_throw(
          try do
            throw(:launch_boom)
          catch
            kind, reason ->
              GrantMint.raise_compensating(g.agent_uri, g.incarnation_id, kind, reason, __STACKTRACE__)
          end
        )

      assert thrown == :launch_boom
      assert GrantRow.get_for_agent(g.agent_uri) == nil

      {:ok, g2} = GrantRow.insert(grant_attrs("throw-leak"))
      failing = fn _u, _i -> {:error, :db_down} end

      assert_raise Ezagent.Credential.GrantCompensationLeaked, fn ->
        try do
          throw(:launch_boom2)
        catch
          kind, reason ->
            GrantMint.raise_compensating(g2.agent_uri, g2.incarnation_id, kind, reason, __STACKTRACE__,
              delete_fun: failing,
              attempts: 2,
              backoff_ms: 1
            )
        end
      end

      assert GrantRow.get_for_agent(g2.agent_uri) != nil
      assert {:ok, :deleted} = GrantRow.delete_incarnation(g2.agent_uri, g2.incarnation_id)
    end
  end

  describe "F3 — incarnation id is minted internally, unconditionally" do
    test "insert overwrites a caller-supplied incarnation_id" do
      attrs = Map.put(grant_attrs("inc-forge"), :incarnation_id, "caller-forged-id")

      {:ok, row} = GrantRow.insert(attrs)

      # Pre-fix `Map.put_new` kept the caller's id, letting a caller reuse a
      # previous incarnation's identity and weakening every incarnation-scoped
      # compare.
      refute row.incarnation_id == "caller-forged-id"
      assert is_binary(row.incarnation_id)
    end
  end

  describe "F4 — incarnation-bound materialization revalidation" do
    test "revalidation rejects a delete+reinsert ABA at the SAME version" do
      attrs = grant_attrs("aba-row")
      {:ok, first} = GrantRow.insert(attrs)
      {:ok, _} = GrantRow.delete(first.agent_uri)

      # Reinsert: version resets to 1 — URI+version is indistinguishable from
      # the first row; only the incarnation differs.
      {:ok, second} = GrantRow.insert(attrs)
      assert second.version == first.version
      refute second.incarnation_id == first.incarnation_id

      # A materializer holding the FIRST fetch's identity must NOT validate.
      assert {:error, :grant_changed} =
               GrantRow.revalidate_version!(first.agent_uri, first.incarnation_id, first.version)

      assert :ok =
               GrantRow.revalidate_version!(
                 second.agent_uri,
                 second.incarnation_id,
                 second.version
               )
    end

    test "materialize_with_grant aborts the commit when the grant is replaced mid-copy" do
      source_a = seed_source("entity://team-a/agent/aba-src-a-#{uniq()}")
      source_b = seed_source("entity://team-a/agent/aba-src-b-#{uniq()}")
      agent_uri = "entity://team-a/agent/aba-mat-#{uniq()}"

      source_dir = Path.join(System.tmp_dir!(), "aba-src-#{uniq()}")
      staging = Path.join(System.tmp_dir!(), "aba-staging-#{uniq()}")
      File.mkdir_p!(source_dir)
      File.mkdir_p!(staging)
      File.write!(Path.join(source_dir, "token.json"), "SECRET-A")

      on_exit(fn ->
        File.rm_rf(source_dir)
        File.rm_rf(staging)
      end)

      {:ok, _g} =
        GrantRow.insert(%{
          agent_uri: agent_uri,
          credential_source_uri: source_a,
          approved_by: "entity://team-a/user/alice",
          approved_scope: source_a,
          version: 1
        })

      test_pid = self()

      # The ABA lands BETWEEN the fetch and the revalidation: while the
      # materializer resolves the source dir, the grant is deleted and
      # reinserted at the SAME version under a NEW incarnation (different
      # source). On the pre-fix branch tip the version-only revalidation
      # passed and the commit fired with the stale secret.
      source_dir_for = fn _uri ->
        {:ok, _} = GrantRow.delete(agent_uri)

        {:ok, _g2} =
          GrantRow.insert(%{
            agent_uri: agent_uri,
            credential_source_uri: source_b,
            approved_by: "entity://team-a/user/alice",
            approved_scope: source_b,
            version: 1
          })

        {:ok, source_dir}
      end

      commit = fn _identity ->
        send(test_pid, :commit_called)
        {:ok, :committed}
      end

      assert {:error, :grant_changed} =
               Ezagent.Agent.Materializer.materialize_with_grant(%{
                 agent_uri: agent_uri,
                 staging: staging,
                 secret_relpaths: ["token.json"],
                 source_dir_for: source_dir_for,
                 commit: commit
               })

      refute_received :commit_called
    end

    test "concurrent reapprovals advance the version ATOMICALLY (distinct versions)" do
      source = "entity://team-a/agent/race-src-#{uniq()}"
      agent_uri = "entity://team-a/agent/race-reapprove-#{uniq()}"

      {:ok, _g} =
        GrantRow.insert(%{
          agent_uri: agent_uri,
          credential_source_uri: source,
          approved_by: "entity://team-a/user/alice",
          approved_scope: source,
          version: 1
        })

      reapprove = fn ->
        GrantRow.reapprove(%{
          agent_uri: agent_uri,
          credential_source_uri: source,
          approved_by: "entity://team-a/user/alice",
          approved_scope: source
        })
      end

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(reapprove) end)
        |> Enum.map(&Task.await(&1, 30_000))

      versions = Enum.map(results, fn {:ok, row} -> row.version end)

      # Pre-fix both racers could read the same prev version and install the
      # same next version; the atomic `inc` gives every reapproval a DISTINCT
      # version and the final row the total.
      assert Enum.sort(versions) == Enum.to_list(2..9)
      assert GrantRow.get_for_agent(agent_uri).version == 9
    end
  end

  describe "F5 — authority-generation-guarded mint" do
    setup do
      suffix = uniq()
      holder_uri = Ezagent.URI.user("team-a", "f5-holder-#{suffix}")
      source_uri = Ezagent.URI.agent("team-a", "f5-source-#{suffix}")
      agent_uri = Ezagent.URI.agent("team-a", "f5-agent-#{suffix}")

      seed_source(URI.to_string(source_uri))

      # Authority rows exist for BOTH the holder and the source (gen 1).
      {:ok, _holder_authority} = Ezagent.Cap.Authority.open(holder_uri, :user)
      {:ok, _source_authority} = Ezagent.Cap.Authority.open(source_uri, :agent)

      cap =
        signed_fixture_cap!(source_uri, :agent, Ezagent.ActionSet.Sandbox, :read, holder_uri)

      # Route the principal gate's independent holder-cap load through the stub.
      previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

      Application.put_env(
        :ezagent_core,
        Ezagent.Cap,
        Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
      )

      Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
        Ezagent.URI.stable_key(holder_uri) => MapSet.new([cap])
      })

      on_exit(fn ->
        Application.put_env(:ezagent_core, Ezagent.Cap, previous)

        Application.delete_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub)
      end)

      {:ok, holder_uri: holder_uri, source_uri: source_uri, agent_uri: agent_uri, cap: cap}
    end

    defp authorize(ctx) do
      Resolver.authorize_grant(%{
        agent_uri: ctx.agent_uri,
        source: ctx.source_uri,
        caller: ctx.holder_uri,
        authenticated_principal: ctx.holder_uri,
        caps: [ctx.cap]
      })
    end

    # A regenesis of an authority: retires the current active row and appends
    # the NEXT generation (the revocation primitive).
    defp regenesis(uri, kind_type) do
      {:ok, authority} = Ezagent.Cap.Authority.regenesis(uri, kind_type)
      authority
    end

    test "authorization records the current holder/source generations", ctx do
      assert {:ok, pending} = authorize(ctx)
      assert pending.kind == :authorized
      assert pending.holder_generation == 1
      assert pending.source_generation == 1

      assert {:ok, grant} = GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))
      assert grant.holder_generation == 1
      assert grant.source_generation == 1
    end

    test "a source regenesis BETWEEN authorize and insert rejects the stale mint", ctx do
      assert {:ok, pending} = authorize(ctx)

      _ = regenesis(ctx.source_uri, :agent)

      # Pre-fix the stale attempt inserted a durable grant minted after the
      # authorizing generation ceased to be current — undetectable forever.
      assert {:error, {:stale_authority_generation, stale}} =
               GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))

      assert Ezagent.URI.stable_key(stale) == Ezagent.URI.stable_key(ctx.source_uri)
      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "a holder regenesis BETWEEN authorize and insert rejects the stale mint", ctx do
      assert {:ok, pending} = authorize(ctx)

      _ = regenesis(ctx.holder_uri, :user)

      assert {:error, {:stale_authority_generation, stale}} =
               GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))

      assert Ezagent.URI.stable_key(stale) == Ezagent.URI.stable_key(ctx.holder_uri)
      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "a regenesis AFTER the mint is detected at materialization fetch", ctx do
      assert {:ok, pending} = authorize(ctx)
      assert {:ok, _grant} = GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))

      _ = regenesis(ctx.source_uri, :agent)

      assert {:error, :stale_authority_generation} =
               GrantRow.fetch_for_materialize(URI.to_string(ctx.agent_uri))
    end

    # #201-cred (codex r2 NEW-HIGH-2) — a regenesis that lands AFTER
    # `fetch_for_materialize/1` but BEFORE the pre-commit / pre-launch
    # revalidation must be caught by `revalidate_version!/3` too, not only by
    # the fetch. The regenesis does NOT change the grant's incarnation or
    # version, so the incarnation+version compare passes; the generation
    # re-check is the crux.
    test "NEW-HIGH-2: revalidate_version! rejects when authority regenerates after fetch", ctx do
      assert {:ok, pending} = authorize(ctx)
      assert {:ok, _grant} = GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))

      agent_uri_str = URI.to_string(ctx.agent_uri)

      # Materializer FETCHES under the current (gen-1) authority.
      assert {:ok, _source, version, incarnation_id} =
               GrantRow.fetch_for_materialize(agent_uri_str)

      # Pre-commit revalidation while the authority is still current → :ok.
      assert :ok = GrantRow.revalidate_version!(agent_uri_str, incarnation_id, version)

      # Source authority regenerates to gen 2 BETWEEN the fetch and the
      # pre-commit / pre-launch revalidation. Incarnation + version are
      # UNCHANGED, so a version/incarnation-only revalidation would still pass
      # (the bug) — the secret authorized under retired gen 1 would commit and
      # launch.
      _ = regenesis(ctx.source_uri, :agent)

      # Pre-fix: :ok (stale secret commits + launches). Post-fix: rejected.
      assert {:error, :grant_changed} =
               GrantRow.revalidate_version!(agent_uri_str, incarnation_id, version)
    end

    # #201-cred (codex r3 HIGH-2) — LOCK-IN at the LAUNCH boundary. The plugin
    # arms call `HomeRuntime.revalidate_grant_before_launch/1` (the wrapper),
    # NOT `revalidate_version!/3` directly, immediately before the sidecar/PTY
    # launch. A regenesis that COMMITTED before that call must DENY the launch.
    # This is GREEN on the round-2 tree (the wrapper already routes through the
    # generation-re-checking `revalidate_version!/3`); it locks the pre-launch
    # generation re-check in place so a refactor cannot silently drop it. The
    # remaining residual (a regenesis committing in the check→`Port.open`
    # micro-interval) is structurally unavoidable — see the wrapper's docs.
    test "HIGH-2 lock-in: revalidate_grant_before_launch denies a committed regenesis", ctx do
      assert {:ok, pending} = authorize(ctx)
      assert {:ok, _grant} = GrantMint.mint(ctx.agent_uri, pending, witness(ctx.agent_uri))

      agent_uri_str = URI.to_string(ctx.agent_uri)

      assert {:ok, _source, version, incarnation_id} =
               GrantRow.fetch_for_materialize(agent_uri_str)

      # The grant_ctx the plugin threads to the pre-launch gate (5-tuple; the
      # minted 5th element is irrelevant to revalidation).
      grant_ctx = {:grant, agent_uri_str, incarnation_id, version, incarnation_id}

      # Still current → the launch is permitted.
      assert :ok = Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)

      # Source authority regenerates (committed) between materialize and launch.
      _ = regenesis(ctx.source_uri, :agent)

      # The pre-launch gate DENIES the launch — no subprocess starts with the
      # secret authorized under the now-retired generation.
      assert {:error, {:grant_changed_before_launch, ^agent_uri_str}} =
               Ezagent.Credential.HomeRuntime.revalidate_grant_before_launch(grant_ctx)
    end

    # #201-cred (codex r2 NEW-HIGH-3) — minting is structurally confined to the
    # created-winner arm: every mint path requires a `CreatedWitness` bound to
    # the agent under mint. A caller with a valid descriptor but no witness (or
    # a witness for a different agent) cannot insert a durable grant.
    test "NEW-HIGH-3: mint WITHOUT a witness inserts no durable grant", ctx do
      assert {:ok, pending} = authorize(ctx)

      # nil witness — the exact bypass codex flagged (a valid descriptor, no
      # `:started ∧ created?` proof).
      assert {:error, :missing_created_winner_witness} =
               GrantMint.mint(ctx.agent_uri, pending, nil)

      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "NEW-HIGH-3: mint with a witness bound to ANOTHER agent is rejected", ctx do
      assert {:ok, pending} = authorize(ctx)

      other = Ezagent.URI.agent("team-a", "not-the-mint-target-#{uniq()}")

      assert {:error, :missing_created_winner_witness} =
               GrantMint.mint(ctx.agent_uri, pending, witness(other))

      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "NEW-HIGH-3: exported authorize_and_mint_grant! is no longer a witness-free bypass",
         ctx do
      args = %{
        agent_uri: ctx.agent_uri,
        source: ctx.source_uri,
        caller: ctx.holder_uri,
        authenticated_principal: ctx.holder_uri,
        caps: [ctx.cap]
      }

      # No witness → structurally rejected, NOTHING written.
      assert {:error, :missing_created_winner_witness} =
               Resolver.authorize_and_mint_grant!(args, nil)

      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil

      # With the created-winner witness the same call mints exactly once.
      assert {:ok, _grant} = Resolver.authorize_and_mint_grant!(args, witness(ctx.agent_uri))
      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) != nil
    end
  end
end
