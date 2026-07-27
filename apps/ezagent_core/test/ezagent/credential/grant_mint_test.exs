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

  defp uniq, do: System.unique_integer([:positive])

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

      assert {:ok, grant} = GrantMint.mint(ctx.agent_uri, pending)
      assert grant.holder_generation == 1
      assert grant.source_generation == 1
    end

    test "a source regenesis BETWEEN authorize and insert rejects the stale mint", ctx do
      assert {:ok, pending} = authorize(ctx)

      _ = regenesis(ctx.source_uri, :agent)

      # Pre-fix the stale attempt inserted a durable grant minted after the
      # authorizing generation ceased to be current — undetectable forever.
      assert {:error, {:stale_authority_generation, stale}} =
               GrantMint.mint(ctx.agent_uri, pending)

      assert Ezagent.URI.stable_key(stale) == Ezagent.URI.stable_key(ctx.source_uri)
      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "a holder regenesis BETWEEN authorize and insert rejects the stale mint", ctx do
      assert {:ok, pending} = authorize(ctx)

      _ = regenesis(ctx.holder_uri, :user)

      assert {:error, {:stale_authority_generation, stale}} =
               GrantMint.mint(ctx.agent_uri, pending)

      assert Ezagent.URI.stable_key(stale) == Ezagent.URI.stable_key(ctx.holder_uri)
      assert GrantRow.get_for_agent(URI.to_string(ctx.agent_uri)) == nil
    end

    test "a regenesis AFTER the mint is detected at materialization fetch", ctx do
      assert {:ok, pending} = authorize(ctx)
      assert {:ok, _grant} = GrantMint.mint(ctx.agent_uri, pending)

      _ = regenesis(ctx.source_uri, :agent)

      assert {:error, :stale_authority_generation} =
               GrantRow.fetch_for_materialize(URI.to_string(ctx.agent_uri))
    end
  end
end
