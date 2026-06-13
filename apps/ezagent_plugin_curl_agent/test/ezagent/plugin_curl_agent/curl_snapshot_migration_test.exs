defmodule Ezagent.PluginCurlAgent.CurlSnapshotMigrationTest do
  @moduledoc """
  PR-6+7 (curl-as-flavor, forward-only) — the `curl_agent` snapshot migration:
  rewrite every pre-fold `curl_agent` `kind_snapshots` row onto the unified
  `Ezagent.Entity.Agent` Kind + `curl` flavor, then prove a cold-load
  rehydrates it identically (conversation + keys + `:creator_uri` + `curl`
  flavor) — Allen overrode the spec's rollback window, so this is the SOLE curl
  path and the migration is the ordered-cutover precondition (the standalone
  curl Kind is DELETED; an un-migrated `curl_agent` row can no longer cold-load).

  `EzagentCore.DataCase` gives the SQL sandbox so the seeded + migrated
  `kind_snapshots` rows are isolated + rolled back per test.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCurlAgent.CurlSnapshotMigration, as: Migration
  alias Ezagent.Behavior.KindBase
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.{Kind, KindRegistry}

  @workspace "workspace://team-alpha"

  # `migrate_state/2` takes the row URI (threaded so `Behavior.Identity.create/1`
  # embeds the agent's self-scoped caps — codex P1). The pure-transform tests
  # don't care which URI, so they share one canonical agent URI.
  defp migrate(state), do: Migration.migrate_state(migrate_uri(), state)
  defp migrate_uri, do: Ezagent.URI.new!("entity://team-alpha/agent/curl_mig-test")

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  # A pre-fold curl_agent state in the two-container slice shape the standalone
  # Kind persisted: a `:curl_agent` slice (NO `:flavor` field — the old Kind
  # never wrote one) + an `:api_keys` slice carrying `:creator_uri`. NO
  # `:kind_base` slice (the standalone Kind was a static non-superset Kind).
  defp legacy_curl_state(opts \\ []) do
    conversation = Keyword.get(opts, :conversation, [])
    creator = Keyword.get(opts, :creator_uri)
    keys = Keyword.get(opts, :keys, %{})
    extra_caps = Keyword.get(opts, :caps, [])

    base = %{
      curl_agent: %{
        state: %{
          provider: "deepseek",
          api_url: "https://api.deepseek.com/chat/completions",
          model: "deepseek-chat",
          system_prompt: nil,
          max_history: 20,
          conversation: conversation,
          last_error: nil,
          last_tokens: nil
        },
        transients: %{}
      },
      api_keys: %{
        state: %{keys: keys, creator_uri: creator},
        transients: %{}
      }
    }

    # Optionally embed a held cap in an :identity slice to exercise the
    # cap-axis rewrite on a worst-case row (the standalone Kind had no
    # :identity slice, but a future/elevated curl agent might carry caps).
    if extra_caps == [] do
      base
    else
      Map.put(base, :identity, %{state: %{caps: MapSet.new(extra_caps)}, transients: %{}})
    end
  end

  defp seed_curl_agent(uri_str, state) do
    binary = :erlang.term_to_binary(state)

    {:ok, _row} =
      KindSnapshot.upsert(uri_str, "curl_agent", binary, 0, @workspace, mark_ever_created: true)

    uri_str
  end

  defp decode(uri_str) do
    {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
    state
  end

  describe "migrate_state/2 (pure transform — spec §6.1 steps 2-4)" do
    test "sets the curl :kind_base behavior set in the two-container shape" do
      migrated = migrate(legacy_curl_state())

      kind_base_key = KindBase.state_slice()
      assert %{state: %{behaviors: behaviors}, transients: %{}} = migrated[kind_base_key]
      # exactly the live curl per-instance set → effective_set picks curl on load
      assert behaviors == Ezagent.Entity.Agent.curl_behaviors()
      assert Ezagent.Behavior.CurlAgent in behaviors
    end

    test "sets flavor: \"curl\" on the :curl_agent slice (O-2 stored field)" do
      pre = legacy_curl_state()
      refute Map.has_key?(pre.curl_agent.state, :flavor)

      migrated = migrate(pre)
      assert migrated.curl_agent.state.flavor == "curl"
    end

    test "preserves the :curl_agent conversation + the :api_keys slice + :creator_uri" do
      creator = Ezagent.URI.new!("entity://team-alpha/user/alice")
      conv = [%{role: "user", content: "hi"}, %{role: "assistant", content: "yo"}]

      migrated =
        migrate(
          legacy_curl_state(
            conversation: conv,
            creator_uri: creator,
            keys: %{"deepseek" => "sk-secret"}
          )
        )

      assert migrated.curl_agent.state.conversation == conv
      assert migrated.api_keys.state.keys == %{"deepseek" => "sk-secret"}
      assert migrated.api_keys.state.creator_uri == creator
    end

    test "rewrites every :curl_agent cap-axis subject to :agent (deep, in any slice)" do
      reset_cap = Capability.cap(:curl_agent, Ezagent.Behavior.CurlAgent, :reset_conversation)
      configure_cap = Capability.cap(:curl_agent, Ezagent.Behavior.CurlAgent, :configure)
      # a non-curl cap must be left untouched
      other_cap = Capability.cap(:agent, Ezagent.Behavior.Identity, :list_caps)

      migrated =
        migrate(legacy_curl_state(caps: [reset_cap, configure_cap, other_cap]))

      caps = migrated.identity.state.caps |> MapSet.to_list()
      kinds = caps |> Enum.map(& &1.kind) |> Enum.sort()

      # both former :curl_agent caps are now :agent; the :agent cap stays :agent
      assert kinds == [:agent, :agent, :agent]
      # actions/behaviors preserved (only the axis moved)
      assert Enum.any?(caps, &(&1.action == :reset_conversation and &1.kind == :agent))
      assert Enum.any?(caps, &(&1.action == :configure and &1.kind == :agent))
      refute Enum.any?(caps, &(&1.kind == :curl_agent))
    end

    test "is idempotent (re-running over a migrated state is a no-op)" do
      once = migrate(legacy_curl_state(creator_uri: nil))
      twice = migrate(once)
      assert twice == once
    end
  end

  describe "run/1 against a seeded curl_agent row (the prod path)" do
    test "rewrites kind_type curl_agent → agent and the in-state fields" do
      uri = "entity://team-alpha/agent/curl_migrate-#{System.unique_integer([:positive])}"
      creator = Ezagent.URI.new!("entity://team-alpha/user/alice")
      conv = [%{role: "user", content: "before migrate"}]

      seed_curl_agent(
        uri,
        legacy_curl_state(conversation: conv, creator_uri: creator, keys: %{"deepseek" => "sk-x"})
      )

      # before: the row is a curl_agent with no flavor / no kind_base
      assert %KindSnapshot{kind_type: "curl_agent"} = KindSnapshot.get(uri)
      pre = decode(uri)
      refute Map.has_key?(pre.curl_agent.state, :flavor)
      refute Map.has_key?(pre, KindBase.state_slice())

      assert {:ok, %{scanned: 1, migrated: 1, already: 0}} = Migration.run()

      # after: kind_type rewritten, flavor set, kind_base materialized,
      # conversation + keys + creator_uri preserved
      assert %KindSnapshot{kind_type: "agent", ever_created: true} = KindSnapshot.get(uri)
      post = decode(uri)
      assert post.curl_agent.state.flavor == "curl"
      assert post.curl_agent.state.conversation == conv
      assert post.api_keys.state.keys == %{"deepseek" => "sk-x"}
      assert post.api_keys.state.creator_uri == creator
      assert post[KindBase.state_slice()].state.behaviors == Ezagent.Entity.Agent.curl_behaviors()

      # gate is green (zero curl_agent rows remain)
      assert {:ok, 0} = Migration.gate()
    end

    test "dry_run reports without writing; gate stays non-zero" do
      uri = "entity://team-alpha/agent/curl_dry-#{System.unique_integer([:positive])}"
      seed_curl_agent(uri, legacy_curl_state())

      assert {:ok, %{scanned: 1, migrated: 0, dry_run: 1}} = Migration.run(dry_run: true)
      # untouched
      assert %KindSnapshot{kind_type: "curl_agent"} = KindSnapshot.get(uri)
      assert {:ok, 1} = Migration.gate()
    end

    test "an undecodable curl_agent row FAILS LOUD (never persists over it)" do
      uri = "entity://team-alpha/agent/curl_corrupt-#{System.unique_integer([:positive])}"
      # empty binary → decode_state :error
      {:ok, _} = KindSnapshot.upsert(uri, "curl_agent", "", 0, @workspace, mark_ever_created: true)

      assert_raise RuntimeError, ~r/undecodable/, fn -> Migration.run() end
    end

    # codex P2 (r5) — a curl_agent row missing a LEGACY-OWNED slice is corrupt;
    # the migration must fail loud, NOT fabricate an empty slice (which would
    # turn it into a migrated agent with lost conversation/keys).
    test "a curl_agent row missing the legacy :curl_agent slice FAILS LOUD" do
      uri = "entity://team-alpha/agent/curl_noslice-#{System.unique_integer([:positive])}"
      # only :api_keys — the :curl_agent conversation slice is gone
      truncated = %{api_keys: %{state: %{keys: %{}, creator_uri: nil}, transients: %{}}}
      seed_curl_agent(uri, truncated)

      assert_raise RuntimeError, ~r/missing the legacy-owned :curl_agent slice/, fn ->
        Migration.run()
      end
    end
  end

  describe "cross-store cap-axis rewrite (codex P1 — :curl_agent → :agent everywhere)" do
    test "rewrite_caps_json/1 flips kind curl_agent → agent, leaves others, idempotent" do
      # the stored caps_json shape (`Capability.Normalize.to_map/1`): the `:kind`
      # axis is the plain-atom string under the "kind" key.
      json =
        Jason.encode!([
          %{
            "kind" => "curl_agent",
            "behavior" => "Elixir.Ezagent.Behavior.CurlAgent",
            "action" => "reset_conversation"
          },
          %{
            "kind" => "agent",
            "behavior" => "Elixir.Ezagent.Behavior.Identity",
            "action" => "list_caps"
          }
        ])

      assert {:changed, rewritten} = Migration.rewrite_caps_json(json)
      decoded = Jason.decode!(rewritten)
      kinds = decoded |> Enum.map(&Map.get(&1, "kind")) |> Enum.sort()
      # the curl cap is now :agent; the pre-existing :agent cap is untouched
      assert kinds == ["agent", "agent"]
      # actions preserved
      assert Enum.any?(decoded, &(&1["action"] == "reset_conversation"))
      # nothing left referencing the deleted curl axis
      refute String.contains?(rewritten, "curl_agent")
      # idempotent + nil/garbage tolerated
      assert {:unchanged, ^rewritten} = Migration.rewrite_caps_json(rewritten)
      assert {:unchanged, nil} = Migration.rewrite_caps_json(nil)
      assert {:unchanged, "not json"} = Migration.rewrite_caps_json("not json")
    end

    test "a NON-curl snapshot holding a :curl_agent cap is rewritten + gated" do
      # e.g. an admin/owner agent granted manage rights over a curl agent, under
      # the old :curl_agent axis — lives in a kind_type:"agent" row, never seen
      # by the curl_agent-row pass.
      uri = "entity://team-alpha/agent/owner_holds_curl-#{System.unique_integer([:positive])}"
      curl_cap = Capability.cap(:curl_agent, Ezagent.Behavior.CurlAgent, :configure)
      foreign = %{identity: %{state: %{caps: MapSet.new([curl_cap])}, transients: %{}}}
      {:ok, _} =
        KindSnapshot.upsert(uri, "agent", :erlang.term_to_binary(foreign), 0, @workspace,
          mark_ever_created: true
        )

      # gate sees the stale cross-store grant BEFORE migration
      assert {:ok, n} = Migration.gate()
      assert n >= 1

      assert {:ok, %{foreign_snapshots_rewritten: r}} = Migration.run()
      assert r >= 1

      # kind_type preserved (foreign row keeps its own Kind), cap axis flipped
      assert %KindSnapshot{kind_type: "agent"} = KindSnapshot.get(uri)
      {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(uri))
      kinds = state.identity.state.caps |> MapSet.to_list() |> Enum.map(& &1.kind)
      assert kinds == [:agent]
      assert {:ok, 0} = Migration.gate()
    end
  end

  describe "cold-load round-trip — a migrated row rehydrates as a unified curl agent" do
    test "cold-loads on Entity.Agent with curl flavor + conversation + keys + creator_uri" do
      uri_str = "entity://team-alpha/agent/curl_coldmig-#{System.unique_integer([:positive])}"
      uri = Ezagent.URI.new!(uri_str)
      creator = Ezagent.URI.new!("entity://team-alpha/user/alice")
      conv = [%{role: "user", content: "survive the migration"}]

      seed_curl_agent(
        uri_str,
        legacy_curl_state(
          conversation: conv,
          creator_uri: creator,
          keys: %{"deepseek" => "sk-coldmig"}
        )
      )

      assert {:ok, %{migrated: 1}} = Migration.run()

      # Cold-load: re-spawn the migrated URI WITHOUT re-passing :behaviors. The
      # persisted :kind_base rehydrates the curl set; ever_created? is true so
      # create/1 is SKIPPED — the flavor/conversation come ONLY from the
      # migrated snapshot. NO ETS flavor attribute is seeded (proves the durable
      # slice, not ETS, drives it).
      assert :none = Ezagent.AgentFlavorAttributes.get(uri)
      {:ok, _pid} = Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The curl slice rehydrated as a unified Entity.Agent curl agent.
      assert {:ok, curl_slice} = Kind.get_slice(uri, :curl_agent)
      assert curl_slice.flavor == "curl"
      assert curl_slice.conversation == conv
      assert curl_slice.provider == "deepseek"

      # Keys + creator_uri survived (key-rotation authz provenance intact).
      assert {:ok, %{keys: %{"deepseek" => "sk-coldmig"}, creator_uri: ^creator}} =
               Kind.get_slice(uri, :api_keys)

      # codex P1 regression: the migration threaded the row URI into
      # Behavior.Identity.create/1, so the migrated agent cold-loads WITH its
      # self-scoped Sandbox.write_path + ConfigEvolve.reconcile_cascade caps
      # (fresh-spawn parity). Without the URI the identity slice is empty and
      # config-evolve self-dispatch is unauthorized.
      assert {:ok, %{caps: identity_caps}} = Kind.get_slice(uri, :identity)
      self_caps = identity_caps |> MapSet.to_list() |> Enum.map(&{&1.behavior, &1.action})
      assert {Ezagent.Behavior.Sandbox, :write_path} in self_caps
      assert {Ezagent.Behavior.ConfigEvolve, :reconcile_cascade} in self_caps

      # The reparented curl Behavior is in the effective set (its public action
      # resolves on Entity.Agent), and :receive is NOT a curl action.
      assert {:ok, Ezagent.Behavior.CurlAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :reset_conversation)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(uri_str) == :error end)
    end
  end
end
