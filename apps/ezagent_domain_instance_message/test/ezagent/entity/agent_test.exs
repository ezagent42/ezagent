defmodule Ezagent.Entity.AgentTest do
  use ExUnit.Case, async: true
  alias Ezagent.Entity.Agent

  describe "Ezagent.Kind contract" do
    test "type_name/0 returns :agent" do
      assert Agent.type_name() == :agent
    end

    test "behaviors/0 returns Agent's hosted behavior slices" do
      # PR2 2026-05-24 (Allen): Sandbox Behavior added — per-agent
      # config_dir_path + Kind.Template plugin extension callbacks.
      #
      # Allen 2026-05-26 — ApiKeys flipped from User Kind to Agent Kind:
      # agents hold their own outbound credentials. `:api_keys` slice
      # now coexists with `:identity` / `:chat` / `:sandbox` on the
      # Agent Kind's snapshot.
      #
      # #17 cascade PR-5 — CredentialGrant hosts the cap-checked
      # operator revoke action on Agent so LiveViews do not write
      # credential_grants directly.
      assert Agent.behaviors() == [
               Ezagent.Behavior.Chat,
               Ezagent.Behavior.Identity,
               Ezagent.Behavior.Sandbox,
               Ezagent.Behavior.ApiKeys,
               Ezagent.Behavior.CredentialGrant
             ]
    end

    test "persistence/0 is {:snapshot, :on_change} (CLI persistence fix 2026-05-25)" do
      # Allen 2026-05-25 — bumped from `:on_terminate` to
      # `{:snapshot, :on_change}` as part of the CLI persistence fix
      # (codex PR r1 HIGH). Under `:on_terminate`, `mix
      # ezagent.agent.create --caps …` would lose the granted caps
      # on mix BEAM exit because `Snapshot.commit/4` returned
      # `:not_durable` on the cap-grant dispatch.
      assert Agent.persistence() == {:snapshot, :on_change}
    end
  end

  describe "session_instance_name/3 — MEDIUM-5 injectivity (hardening round 2)" do
    test "distinct slot names whose sanitized forms collide get DISTINCT instance names" do
      # `api.v1` and `api-v1` both sanitize (non-`[a-zA-Z0-9_-]` → `-`)
      # to `api-v1`. Pre-round-2 they collapsed to the SAME instance
      # name, so the 2nd slot in a session reused the 1st worker URI.
      disc = "gen-1234-5"

      name_a = Agent.session_instance_name("api.v1", disc)
      name_b = Agent.session_instance_name("api-v1", disc)

      refute name_a == name_b,
             "api.v1 and api-v1 must produce DISTINCT instance names — got #{name_a}"
    end

    test "the appended slot hash is stable across calls" do
      disc = "gen-1234-5"

      assert Agent.session_instance_name("api.v1", disc) ==
               Agent.session_instance_name("api.v1", disc)
    end

    test "instance names stay URI-safe (only [a-zA-Z0-9_-])" do
      name = Agent.session_instance_name("weird name!.v2", "gen-9 9", 3)
      assert Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name)
    end

    test "distinct slots in one session are pairwise unique (a small fan-out)" do
      disc = "gen-7777-1"

      names =
        ["api.v1", "api-v1", "api_v1", "api/v1", "api v1", "worker-a", "worker.a"]
        |> Enum.map(&Agent.session_instance_name(&1, disc))

      assert length(Enum.uniq(names)) == length(names),
             "every distinct slot name in a session must map to a distinct instance name"
    end

    test "the generation counter still differentiates a same-slot swap" do
      disc = "gen-1234-5"

      assert Agent.session_instance_name("api.v1", disc, 0) !=
               Agent.session_instance_name("api.v1", disc, 1)
    end
  end
end
