defmodule Ezagent.Credential.ResolverTest do
  @moduledoc """
  #17 agent-provisioning-cascade PR-1 — PURE-logic invariants for the resolution core
  (spec §4 / §D2 / §D4.3). No DB: the credential-source availability check is injected
  via `source_available?`, and the user-pointer absence path is exercised here by NOT
  seeding a pointer (the DB-backed pointer-present path lives in the DataCase test).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Credential.Resolver

  @agent Ezagent.URI.new!("entity://team-a/agent/worker1")
  @owner Ezagent.URI.new!("entity://team-a/user/alice")
  @ws Ezagent.URI.new!("workspace://team-a")
  @session Ezagent.URI.new!("session://team-a/default/s1")
  @explicit Ezagent.URI.new!("entity://team-a/agent/shared-svc")
  @user_src Ezagent.URI.new!("entity://team-a/agent/alice-base")

  defp always_available(_uri), do: true
  defp never_available(_uri), do: false

  # ── (a) layer ORDER: flavor-base → workspace → user → session ──────────────

  test "resolve_layers enumerates the four layers low→high in spec order" do
    {:ok, %{config_layers: layers}} =
      Resolver.resolve_layers(%{
        agent_uri: @agent,
        owner_uri: @owner,
        workspace_uri: @ws,
        session_uri: @session,
        explicit_source: @explicit,
        flavor: "cc",
        source_available?: &always_available/1
      })

    assert Enum.map(layers, & &1.layer) == [:flavor_base, :workspace, :user, :session]
  end

  test "absent workspace + session layers are still enumerated IN ORDER, marked not present" do
    {:ok, %{config_layers: layers}} =
      Resolver.resolve_layers(%{
        agent_uri: @agent,
        owner_uri: @owner,
        # no workspace, no session
        explicit_source: @explicit,
        flavor: "cc",
        source_available?: &always_available/1
      })

    # order is invariant regardless of which optional layers are present
    assert Enum.map(layers, & &1.layer) == [:flavor_base, :workspace, :user, :session]

    by = Map.new(layers, &{&1.layer, &1.present})
    assert by[:flavor_base] == true
    assert by[:workspace] == false
    assert by[:user] == true
    assert by[:session] == false
  end

  test "resolve_layers returns the picked secret_source alongside config_layers" do
    {:ok, resolved} =
      Resolver.resolve_layers(%{
        agent_uri: @agent,
        owner_uri: @owner,
        workspace_uri: @ws,
        explicit_source: @explicit,
        flavor: "cc",
        source_available?: &always_available/1
      })

    assert resolved.secret_source == @explicit
  end

  # ── (b) credential-source PRECEDENCE: explicit > user > workspace > fail ────

  test "explicit source wins (precedence #1) — used even when available" do
    assert {:ok, @explicit} =
             Resolver.pick_credential_source(%{
               explicit_source: @explicit,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               source_available?: &always_available/1
             })
  end

  test "no source at all + credential required → fail loud (precedence #4)" do
    # no explicit, no user pointer (absent), no workspace-shared (PR-3) → fail loud
    assert {:error, :no_credential_source} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               credential_required?: true,
               user_source_lookup: fn -> :absent end,
               workspace_shared_lookup: fn -> :absent end,
               source_available?: &always_available/1
             })
  end

  test "no source + credential NOT required → {:ok, nil} (no fail-loud)" do
    assert {:ok, nil} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               credential_required?: false,
               user_source_lookup: fn -> :absent end,
               workspace_shared_lookup: fn -> :absent end,
               source_available?: &always_available/1
             })
  end

  # ── (c) absent vs revoked distinction ──────────────────────────────────────

  test "ABSENT user pointer FALLS THROUGH (here: to the fail-loud workspace step, not an error about the user source)" do
    # No user pointer seeded ⇒ absent ⇒ fall through. With no workspace-shared yet (PR-3),
    # the fall-through lands on :no_credential_source — crucially NOT :user_source_*.
    assert {:error, :no_credential_source} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               user_source_lookup: fn -> :absent end,
               workspace_shared_lookup: fn -> :absent end,
               source_available?: &always_available/1
             })
  end

  test "REVOKED explicit source FAILS LOUD and does NOT fall through" do
    assert {:error, {:explicit_source_unavailable, @explicit}} =
             Resolver.pick_credential_source(%{
               explicit_source: @explicit,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               # the explicitly-named source is revoked/deleted/unauthorized
               source_available?: &never_available/1
             })
  end

  test "an explicit unavailable source NEVER silently downgrades to the user/workspace layer" do
    # Even if a user pointer would resolve, an explicit-but-revoked source must NOT
    # fall through — it must fail loud with the explicit-source error.
    result =
      Resolver.pick_credential_source(%{
        explicit_source: @explicit,
        owner_uri: @owner,
        workspace_uri: @ws,
        flavor: "cc",
        source_available?: fn uri -> uri == @user_src end
      })

    assert {:error, {:explicit_source_unavailable, @explicit}} = result
  end

  test "PRESENT user source (injected) wins over fail-loud (precedence #2)" do
    assert {:ok, @user_src} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               user_source_lookup: fn -> {:ok, @user_src} end,
               source_available?: &always_available/1
             })
  end

  test "PRESENT-but-revoked user source FAILS LOUD, does NOT fall through (absent≠revoked)" do
    assert {:error, {:user_source_unavailable, @user_src}} =
             Resolver.pick_credential_source(%{
               explicit_source: nil,
               owner_uri: @owner,
               workspace_uri: @ws,
               flavor: "cc",
               user_source_lookup: fn -> {:ok, @user_src} end,
               # the pointed user source was revoked/deleted ⇒ unavailable
               source_available?: &never_available/1
             })
  end

  # ── grant cap-check (pure half) ────────────────────────────────────────────

  test "source_read_authorized? rejects unsigned legacy caps and insufficient caps" do
    good = Ezagent.Credential.GrantCap.read_cap_for(@explicit)
    # a cap for a DIFFERENT source must not authorize reading @explicit
    wrong = Ezagent.Credential.GrantCap.read_cap_for(@user_src)

    refute Resolver.source_read_authorized?(@owner, @explicit, [good])
    refute Resolver.source_read_authorized?(@owner, @explicit, [wrong])
    refute Resolver.source_read_authorized?(@owner, @explicit, [])
  end

  # codex H1 (PR-1 re-review): a workspace-shared resolver ERROR must FAIL LOUD, never be
  # silently collapsed to "absent". The lookup is injected to drive the three outcomes.
  describe "pick_credential_source/1 — workspace-shared lookup (D4.3 step 3, fail-loud)" do
    @ws_shared Ezagent.URI.new!("entity://team-a/agent/ws-service")

    defp base_opts(extra) do
      Map.merge(
        %{
          owner_uri: @owner,
          workspace_uri: @ws,
          flavor: "cc",
          user_source_lookup: fn -> :absent end,
          source_available?: &always_available/1
        },
        extra
      )
    end

    test "absent user + present+available workspace-shared → uses the shared source" do
      assert {:ok, @ws_shared} =
               Resolver.pick_credential_source(
                 base_opts(%{workspace_shared_lookup: fn -> {:ok, @ws_shared} end})
               )
    end

    test "absent user + absent workspace-shared + required → fail loud (no source)" do
      assert {:error, :no_credential_source} =
               Resolver.pick_credential_source(
                 base_opts(%{workspace_shared_lookup: fn -> :absent end})
               )
    end

    test "absent user + absent workspace-shared + NOT required → {:ok, nil}" do
      assert {:ok, nil} =
               Resolver.pick_credential_source(
                 base_opts(%{
                   workspace_shared_lookup: fn -> :absent end,
                   credential_required?: false
                 })
               )
    end

    test "workspace-shared resolver ERROR → FAIL LOUD, not absent (codex H1)" do
      assert {:error, {:workspace_source_unavailable, :unauthorized}} =
               Resolver.pick_credential_source(
                 base_opts(%{
                   workspace_shared_lookup: fn ->
                     {:error, {:workspace_source_unavailable, :unauthorized}}
                   end
                 })
               )
    end

    test "present-but-unavailable workspace-shared (revoked/deleted) → fail loud" do
      assert {:error, {:workspace_source_unavailable, @ws_shared}} =
               Resolver.pick_credential_source(
                 base_opts(%{
                   workspace_shared_lookup: fn -> {:ok, @ws_shared} end,
                   source_available?: &never_available/1
                 })
               )
    end

    # codex H1 re-review: the DEFAULT lookup's UriQuery-result classifier. Only the EXACT
    # dispatcher-absence (no resolver for THIS attr) is absent; a registered resolver's own
    # error — including a DIFFERENT no_resolver attr — must fail loud, not collapse.
    test "classify_workspace_shared_result: only the exact attr no_resolver is absent" do
      alias Ezagent.Credential.Resolver, as: R
      assert {:ok, %URI{}} = R.classify_workspace_shared_result({:ok, "entity://team-a/agent/x"})
      assert :absent = R.classify_workspace_shared_result(:none)

      assert :absent =
               R.classify_workspace_shared_result(
                 {:error, {:no_resolver, :workspace_shared_credential_source}}
               )

      # a registered resolver propagating a FOREIGN no_resolver → fail loud (codex H1)
      assert {:error, {:workspace_source_unavailable, {:no_resolver, :some_dependency}}} =
               R.classify_workspace_shared_result({:error, {:no_resolver, :some_dependency}})

      assert {:error, {:workspace_source_unavailable, :unauthorized}} =
               R.classify_workspace_shared_result({:error, :unauthorized})
    end
  end
end
