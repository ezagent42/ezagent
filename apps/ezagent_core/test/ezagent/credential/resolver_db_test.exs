defmodule Ezagent.Credential.ResolverDbTest do
  @moduledoc """
  #17 agent-provisioning-cascade PR-1 — DB-backed resolution invariants (spec §D4.3 /
  §5.1 / §5.2). Exercises the REAL stores: the §5.2 user-source pointer (seeded via the
  authorized `Adopt` chokepoint, like the PR-0 adopt test) and the §5.1 grant mint
  (`GrantRow`). Pure-logic order/precedence lives in `Ezagent.Credential.ResolverTest`.
  """
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references `Ezagent.Users` (sibling app
  # ezagent_domain_identity). Runs only in the umbrella; excluded standalone.
  @moduletag :umbrella_only

  alias Ezagent.Credential.{Adopt, GrantCap, GrantRow, Resolver}
  alias Ezagent.Kind.CreatedWitness
  alias Ezagent.Users

  @ws "team-a"

  # #201-cred (codex r2 NEW-HIGH-3) — the created-winner witness a genuine spawn
  # would mint. `authorize_and_mint_grant!/2` now requires one; the authz-failure
  # tests below fail at `authorize_grant/1` BEFORE the mint, so their witness is
  # inert (present only to satisfy the arity).
  defp witness(%URI{} = agent_uri), do: CreatedWitness.new(agent_uri)

  defp seed_agent(uri_str, owner, flavor) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri = Ezagent.URI.new!(uri_str)
    :ok = Ezagent.AgentLineage.record(uri, owner)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, flavor)
    uri_str
  end

  # System-principal elimination (#154, 2026-06-19) — the operator credential
  # adopt path now dispatches `:set_default_credential_source` under the real
  # admin entity carrying the INLINE per-action cap scoped to the OWNER (the
  # step-5.5 authorizer), replacing the eliminated `system://mix-task` wildcard.
  defp admin_uri, do: Ezagent.Entity.User.admin_uri()

  defp admin_caps(owner_str) do
    owner_uri = Ezagent.URI.new!(owner_str)

    target =
      Ezagent.URI.with_action(
        owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    [
      signed_fixture_cap!(
        target,
        :user,
        Ezagent.ActionSet.UserDefaultCredentialSource,
        :set_default_credential_source,
        admin_uri()
      )
    ]
  end

  setup do
    suffix = System.unique_integer([:positive])
    owner_uri = Ezagent.URI.new!("entity://#{@ws}/user/alice#{suffix}")
    owner_str = URI.to_string(owner_uri)

    base = seed_agent("entity://#{@ws}/agent/alice-base-#{suffix}", owner_str, "cc")

    # The agent we are PROVISIONING (flavor cc so the user pointer keys on cc).
    new_agent = seed_agent("entity://#{@ws}/agent/worker-#{suffix}", owner_str, "cc")

    {:ok, _} = Users.create(owner_str, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner_uri)

    {:ok,
     owner_uri: owner_uri, owner_str: owner_str, base: base, new_agent: new_agent, suffix: suffix}
  end

  # ── (b)+(c) DB: user pointer PRESENT wins; pointer ABSENT falls through ─────

  test "PRESENT user pointer is selected (precedence #2) — read from the §5.2 pointer, not name-inferred",
       ctx do
    # seed the user default source pointer via the authorized chokepoint
    {:ok, _} =
      Adopt.adopt(ctx.owner_str, @ws, "cc", [ctx.base],
        caller: admin_uri(),
        authenticated_principal: admin_uri(),
        caps: admin_caps(ctx.owner_str)
      )

    assert {:ok, picked} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: ctx.owner_uri,
               workspace_uri: Ezagent.URI.workspace(@ws),
               flavor: "cc",
               # the pointed source exists ⇒ available
               source_available?: fn _ -> true end
             })

    assert URI.to_string(picked) == ctx.base
  end

  test "ABSENT user pointer (none seeded for this flavor) falls through → fail loud (no workspace-shared in PR-1)",
       ctx do
    assert {:error, :no_credential_source} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: ctx.owner_uri,
               workspace_uri: Ezagent.URI.workspace(@ws),
               flavor: "codex",
               source_available?: fn _ -> true end
             })
  end

  test "PRESENT user pointer whose source is REVOKED/deleted FAILS LOUD, does NOT fall through",
       ctx do
    {:ok, _} =
      Adopt.adopt(ctx.owner_str, @ws, "cc", [ctx.base],
        caller: admin_uri(),
        authenticated_principal: admin_uri(),
        caps: admin_caps(ctx.owner_str)
      )

    base_uri = Ezagent.URI.new!(ctx.base)

    assert {:error, {:user_source_unavailable, ^base_uri}} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: ctx.owner_uri,
               workspace_uri: Ezagent.URI.workspace(@ws),
               flavor: "cc",
               # the pointed source was revoked/deleted ⇒ unavailable
               source_available?: fn _ -> false end
             })
  end

  test "default availability uses the durable snapshot: a seeded source is available, a ghost is not",
       ctx do
    {:ok, _} =
      Adopt.adopt(ctx.owner_str, @ws, "cc", [ctx.base],
        caller: admin_uri(),
        authenticated_principal: admin_uri(),
        caps: admin_caps(ctx.owner_str)
      )

    # No injected predicate → uses SnapshotStore existence. base was seeded ⇒ picked.
    assert {:ok, picked} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: ctx.owner_uri,
               workspace_uri: Ezagent.URI.workspace(@ws),
               flavor: "cc"
             })

    assert URI.to_string(picked) == ctx.base
  end

  # ── grant minted at CREATE with cap-check (spec §5.1) ──────────────────────

  test "authorize_and_mint_grant! mints a GrantRow when the caller holds sandbox.read on the source",
       ctx do
    source = Ezagent.URI.new!(ctx.base)
    agent = Ezagent.URI.new!(ctx.new_agent)

    good_cap =
      signed_fixture_cap!(
        source,
        :agent,
        Ezagent.ActionSet.Sandbox,
        :read,
        ctx.owner_uri
      )

    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(ctx.owner_uri) => MapSet.new([good_cap])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    assert {:ok, grant} =
             Resolver.authorize_and_mint_grant!(
               %{
                 agent_uri: agent,
                 source: source,
                 approved_by: ctx.owner_uri,
                 caller: ctx.owner_uri,
                 authenticated_principal: ctx.owner_uri,
                 caps: [good_cap]
               },
               witness(agent)
             )

    assert grant.credential_source_uri == ctx.base
    # approved_scope == source so PR-0 fetch_for_materialize scope-identity check holds
    assert grant.approved_scope == ctx.base
    assert grant.version == 1
    # durable: the grant is readable + active
    assert GrantRow.active?(ctx.new_agent)
  end

  test "a source read under WRONG/insufficient caps is rejected — NO grant minted", ctx do
    source = Ezagent.URI.new!(ctx.base)
    agent = Ezagent.URI.new!(ctx.new_agent)
    # a cap for a DIFFERENT source does not authorize reading `source`
    wrong_cap = GrantCap.read_cap_for(Ezagent.URI.new!("entity://#{@ws}/agent/other"))

    assert {:error, {:source_unauthorized, ^source}} =
             Resolver.authorize_and_mint_grant!(
               %{
                 agent_uri: agent,
                 source: source,
                 approved_by: ctx.owner_uri,
                 caller: ctx.owner_uri,
                 authenticated_principal: ctx.owner_uri,
                 caps: [wrong_cap]
               },
               witness(agent)
             )

    refute GrantRow.active?(ctx.new_agent)
  end

  test "NEVER mints a grant under any system:// principal's caps (codex H1)", ctx do
    source = Ezagent.URI.new!(ctx.base)
    agent = Ezagent.URI.new!(ctx.new_agent)
    # System-principal elimination (#154, 2026-06-19) — the guard was generalized
    # from the (now-deleted) `system://agent-internal` to ANY `system://` caller.
    # Use the most-privileged system principal (`bootstrap`) to prove even it is
    # refused: a system principal is an authorizer, never an accountable approver.
    system_caller = Ezagent.URI.new!("system://bootstrap")
    # even with a 'good' cap, a system-principal caller/approver is refused outright
    good_cap = GrantCap.read_cap_for(source)

    assert {:error, :system_principal_forbidden} =
             Resolver.authorize_and_mint_grant!(
               %{
                 agent_uri: agent,
                 source: source,
                 approved_by: system_caller,
                 caller: system_caller,
                 authenticated_principal: system_caller,
                 caps: [good_cap]
               },
               witness(agent)
             )

    refute GrantRow.active?(ctx.new_agent)
  end

  test "rejects a forged approver (approved_by != the cap-checked caller) — no grant (codex)",
       ctx do
    source = Ezagent.URI.new!(ctx.base)
    agent = Ezagent.URI.new!(ctx.new_agent)
    good_cap = GrantCap.read_cap_for(source)

    assert {:error, :approver_must_be_caller} =
             Resolver.authorize_and_mint_grant!(
               %{
                 agent_uri: agent,
                 source: source,
                 approved_by: Ezagent.URI.new!("entity://#{@ws}/user/someone-else"),
                 caller: ctx.owner_uri,
                 authenticated_principal: ctx.owner_uri,
                 caps: [good_cap]
               },
               witness(agent)
             )

    refute GrantRow.active?(ctx.new_agent)
  end

  test "rejects minting a grant for an agent in a DIFFERENT workspace than the source (codex)",
       ctx do
    source = Ezagent.URI.new!(ctx.base)
    foreign_agent = Ezagent.URI.new!("entity://other-ws/agent/x")
    good_cap = GrantCap.read_cap_for(source)

    assert {:error, :agent_source_workspace_mismatch} =
             Resolver.authorize_and_mint_grant!(
               %{
                 agent_uri: foreign_agent,
                 source: source,
                 approved_by: ctx.owner_uri,
                 caller: ctx.owner_uri,
                 authenticated_principal: ctx.owner_uri,
                 caps: [good_cap]
               },
               witness(foreign_agent)
             )

    refute GrantRow.active?("entity://other-ws/agent/x")
  end

  # ── resolve_layers end-to-end against DB ───────────────────────────────────

  test "resolve_layers returns ordered layers + the DB-resolved user source as secret_source",
       ctx do
    {:ok, _} =
      Adopt.adopt(ctx.owner_str, @ws, "cc", [ctx.base],
        caller: admin_uri(),
        authenticated_principal: admin_uri(),
        caps: admin_caps(ctx.owner_str)
      )

    assert {:ok, %{config_layers: layers, secret_source: secret}} =
             Resolver.resolve_layers(%{
               agent_uri: Ezagent.URI.new!(ctx.new_agent),
               owner_uri: ctx.owner_uri,
               workspace_uri: Ezagent.URI.workspace(@ws),
               flavor: "cc",
               source_available?: fn _ -> true end
             })

    assert Enum.map(layers, & &1.layer) == [:flavor_base, :workspace, :user, :session]
    assert URI.to_string(secret) == ctx.base
  end
end
