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
        agent_slots: [{"a", URI.parse("template://agent/default/x")}],
        version_hash: nil
      }

      assert SessionTemplate.compute_version_hash(slice) ==
               SessionTemplate.compute_version_hash(slice)
    end

    test "different slice content → different hash (collision resistance)" do
      slice_a = %{name: "a", agent_slots: []}
      slice_b = %{name: "b", agent_slots: []}

      refute SessionTemplate.compute_version_hash(slice_a) ==
               SessionTemplate.compute_version_hash(slice_b)
    end

    test "created_at / created_by do NOT affect hash (content-addressable means stable across saves)" do
      slice_a = %{
        name: "stable",
        agent_slots: [],
        created_at: ~U[2026-05-18 10:00:00Z],
        created_by: URI.parse("entity://user/default/alice")
      }

      slice_b = %{
        name: "stable",
        agent_slots: [],
        created_at: ~U[2026-12-31 23:59:59Z],
        created_by: URI.parse("entity://user/default/bob")
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
  end

  describe "build_uri/2" do
    test "constructs template://session/<workspace>/<name>@<hash> URI shape (SPEC v3 §3.6 PR-7)" do
      hash = String.duplicate("a", 64)
      uri = SessionTemplate.build_uri("code-review", hash)

      assert uri.scheme == "template"
      assert uri.host == "session"
      # PR-7 adds workspace segment; default workspace is `default`.
      assert uri.path == "/default/code-review@" <> hash
    end

    test "build_uri/3 with explicit workspace places template in workspace path segment" do
      hash = String.duplicate("b", 64)
      uri = SessionTemplate.build_uri("code-review", hash, workspace: "team-alpha")

      assert uri.path == "/team-alpha/code-review@" <> hash
    end
  end
end
