defmodule Ezagent.Entity.SessionTemplateTest do
  @moduledoc """
  Phase 7 PR 38 — SessionTemplate Kind structural + hash invariant tests.

  Pin the Kind contract surface + git-style versioning semantics
  (D7-10). End-to-end Generator (spawn_from_template) is covered by
  PR 41; fork/merge by PR 46 (orchestrator tools).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Entity.SessionTemplate

  test "type_name/0 returns :session_template" do
    assert SessionTemplate.type_name() == :session_template
  end

  test "behaviors/0 includes Identity (caps + slice edit dispatch)" do
    assert Ezagent.Behavior.Identity in SessionTemplate.behaviors()
  end

  test "behaviors/0 includes Behavior.Template (Phase 7 completion PR-1 — content slice)" do
    assert Ezagent.Behavior.Template in SessionTemplate.behaviors(),
           "SessionTemplate must carry Behavior.Template so the versioned " <>
             ":template content slice has dispatchable actions (SPEC §1.0)"
  end

  test "persistence/0 is {:snapshot, :on_change} — versioned templates survive restart" do
    assert SessionTemplate.persistence() == {:snapshot, :on_change}
  end

  describe "compute_version_hash/1 (D7-10 git-style content addressing)" do
    test "produces a 64-char lowercase hex SHA-256 digest" do
      slice = %{
        name: "test",
        description: "test desc",
        agent_slots: [],
        routing_rules: [],
        default_workspace_uri: URI.parse("workspace://test")
      }

      hash = SessionTemplate.compute_version_hash(slice)

      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash == String.downcase(hash)
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "same slice content → same hash (deterministic)" do
      slice = %{
        name: "stable",
        agent_slots: [{"a", URI.parse("template://agent/team-alpha/x")}],
        version_hash: nil
      }

      assert SessionTemplate.compute_version_hash(slice) ==
               SessionTemplate.compute_version_hash(slice)
    end

    test "different slice content → different hash (collision resistance)" do
      # Phase 7 completion PR-5 (SPEC §1.3) — `name` is EXCLUDED from
      # the hash input (a rename is not a new config version), so the
      # collision-resistance witness must differ on a hashed field:
      # here `description`.
      slice_a = %{name: "x", description: "config a", agent_slots: []}
      slice_b = %{name: "x", description: "config b", agent_slots: []}

      refute SessionTemplate.compute_version_hash(slice_a) ==
               SessionTemplate.compute_version_hash(slice_b)
    end

    test "name does NOT affect hash (SPEC §1.3 — a rename is not a new version)" do
      slice_a = %{name: "alpha", description: "same", agent_slots: []}
      slice_b = %{name: "beta", description: "same", agent_slots: []}

      assert SessionTemplate.compute_version_hash(slice_a) ==
               SessionTemplate.compute_version_hash(slice_b),
             "hash input must exclude `name` — two sessions with an identical " <>
               "team config saved under different names must hash identically " <>
               "(SPEC §1.3 build-working-copy GATE)"
    end

    test "created_at / created_by do NOT affect hash (content-addressable means stable across saves)" do
      slice_a = %{
        name: "stable",
        agent_slots: [],
        created_at: ~U[2026-05-18 10:00:00Z],
        created_by: URI.parse("entity://user/team-alpha/alice")
      }

      slice_b = %{
        name: "stable",
        agent_slots: [],
        created_at: ~U[2026-12-31 23:59:59Z],
        created_by: URI.parse("entity://user/team-alpha/bob")
      }

      assert SessionTemplate.compute_version_hash(slice_a) ==
               SessionTemplate.compute_version_hash(slice_b),
             "hash must ignore created_at + created_by — otherwise the same config " <>
               "saved by different users at different times produces different hashes " <>
               "(violates content-addressable contract)"
    end

    test "version_hash / version_tag fields do NOT affect hash (self-reference avoidance)" do
      slice_a = %{name: "x", agent_slots: [], version_hash: "old-hash", version_tag: nil}
      slice_b = %{name: "x", agent_slots: [], version_hash: "different-hash", version_tag: "v1.0"}

      assert SessionTemplate.compute_version_hash(slice_a) ==
               SessionTemplate.compute_version_hash(slice_b),
             "hash input must exclude version_hash + version_tag — otherwise hash depends on prior hash, infinite recursion"
    end

    test "agent_slots (atom OR string key) does NOT affect hash (codex MINOR — PR-8 removed slot tools)" do
      base = %{name: "x", description: "same team"}

      # `agent_slots` is no longer a content field — neither the atom nor
      # the string key may ride into the version hash. A template with a
      # vestigial slot list must hash identically to one without.
      with_atom = Map.put(base, :agent_slots, [{"backend", "template://agent/team-alpha/be"}])
      with_string = Map.put(base, "agent_slots", [%{"slot" => "frontend"}])

      assert SessionTemplate.compute_version_hash(base) ==
               SessionTemplate.compute_version_hash(with_atom)

      assert SessionTemplate.compute_version_hash(base) ==
               SessionTemplate.compute_version_hash(with_string)
    end
  end

  describe "build_uri/2" do
    test "constructs template://session/<workspace>/<name>@<hash> URI shape (SPEC v3 §3.6 PR-7)" do
      hash = String.duplicate("a", 64)
      uri = SessionTemplate.build_uri("code-review", hash, workspace: "team-alpha")

      assert uri.scheme == "template"
      assert uri.host == "session"
      # SPEC #324: workspace is required (no silent `"default"` fallback).
      assert uri.path == "/team-alpha/code-review@" <> hash
    end

    test "build_uri/3 with explicit workspace places template in workspace path segment" do
      hash = String.duplicate("b", 64)
      uri = SessionTemplate.build_uri("code-review", hash, workspace: "team-alpha")

      assert uri.path == "/team-alpha/code-review@" <> hash
    end
  end
end
