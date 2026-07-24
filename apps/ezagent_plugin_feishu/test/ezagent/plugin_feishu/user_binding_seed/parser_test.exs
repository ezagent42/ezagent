defmodule EzagentPluginFeishu.UserBindingSeed.ParserTest do
  @moduledoc """
  Handoff B1 Phase 1 — table-driven strict-schema tests for the
  Feishu user-binding seed file parser.

  Pure module: no DB, no dispatch. Schema:

      bindings:
        - open_id: "fake_..."
          user_uri: "entity://team-alpha/user/alice"

  Every rejection case must fire on the FILE CONTENT ALONE — none of
  these tests touch the DB, proving zero-mutation-on-invalid at the
  parser layer (the importer-level "zero mutation" DoD item additionally
  proves no dispatch fires; see user_binding_seed_test.exs).
  """
  use ExUnit.Case, async: true

  alias EzagentPluginFeishu.UserBindingSeed.Parser

  describe "valid input" do
    test "parses a well-formed single row" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "entity://team-alpha/user/alice"
      """

      assert {:ok, [row]} = Parser.parse_and_validate(yaml)
      assert row.open_id == "ou_abc123"
      assert %URI{scheme: "entity"} = row.user_uri
      assert URI.to_string(row.user_uri) == "entity://team-alpha/user/alice"
      assert row.row == 1
    end

    test "parses multiple rows preserving file order + 1-based row index" do
      yaml = """
      bindings:
        - open_id: "ou_1"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "ou_2"
          user_uri: "entity://team-beta/user/bob"
      """

      assert {:ok, [row1, row2]} = Parser.parse_and_validate(yaml)
      assert row1.open_id == "ou_1"
      assert row1.row == 1
      assert row2.open_id == "ou_2"
      assert row2.row == 2
    end

    test "empty bindings list is valid (no-op file)" do
      assert {:ok, []} = Parser.parse_and_validate("bindings: []\n")
    end
  end

  describe "malformed YAML" do
    test "unparsable YAML syntax fails loud" do
      assert {:error, {:malformed_yaml, _}} = Parser.parse_and_validate("bindings: [\n  - broken")
    end
  end

  describe "wrong top-level shape" do
    test "missing bindings key" do
      assert {:error, {:invalid_shape, _}} = Parser.parse_and_validate("other: 1\n")
    end

    test "bindings is not a list" do
      assert {:error, {:invalid_shape, _}} = Parser.parse_and_validate("bindings: \"nope\"\n")
    end

    test "top-level is not a map (bare scalar document)" do
      assert {:error, {:invalid_shape, _}} = Parser.parse_and_validate("just a string\n")
    end

    test "top-level is a list, not a map" do
      assert {:error, {:invalid_shape, _}} = Parser.parse_and_validate("- 1\n- 2\n")
    end
  end

  describe "wrong row shape / unknown fields" do
    test "row is not a map" do
      yaml = """
      bindings:
        - "not-a-map"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "row missing open_id" do
      yaml = """
      bindings:
        - user_uri: "entity://team-alpha/user/alice"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "row missing user_uri" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "row has an unknown extra field" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "entity://team-alpha/user/alice"
          note: "unexpected"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end
  end

  describe "empty fields" do
    test "empty open_id" do
      yaml = """
      bindings:
        - open_id: ""
          user_uri: "entity://team-alpha/user/alice"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "empty user_uri" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: ""
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end
  end

  describe "illegal / non-canonical URIs" do
    test "person:// scheme is rejected" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "person://team-alpha/alice"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "workspace:// scheme is rejected (not a user URI)" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "workspace://team-alpha"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "entity URI of a non-user type (agent) is rejected" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "entity://team-alpha/agent/some_agent"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "bare name with no scheme (implicit workspace) is rejected — no promotion" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "alice"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end

    test "structurally malformed URI string is rejected" do
      yaml = """
      bindings:
        - open_id: "ou_abc123"
          user_uri: "entity://"
      """

      assert {:error, {:invalid_row, 1, _}} = Parser.parse_and_validate(yaml)
    end
  end

  describe "duplicate open_id" do
    test "duplicate open_id with the SAME user_uri still rejects the whole file" do
      yaml = """
      bindings:
        - open_id: "ou_dup"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "ou_dup"
          user_uri: "entity://team-alpha/user/alice"
      """

      assert {:error, {:duplicate_open_id, _fingerprint, [1, 2]}} =
               Parser.parse_and_validate(yaml)
    end

    test "duplicate open_id with DIFFERENT user_uri rejects the whole file" do
      yaml = """
      bindings:
        - open_id: "ou_dup"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "ou_dup"
          user_uri: "entity://team-beta/user/bob"
      """

      assert {:error, {:duplicate_open_id, _fingerprint, [1, 2]}} =
               Parser.parse_and_validate(yaml)
    end

    test "duplicate error does not include the raw open_id or user_uri (redaction)" do
      yaml = """
      bindings:
        - open_id: "ou_super_secret_dup"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "ou_super_secret_dup"
          user_uri: "entity://team-alpha/user/alice"
      """

      {:error, {:duplicate_open_id, fingerprint, _rows}} = Parser.parse_and_validate(yaml)
      refute fingerprint =~ "ou_super_secret_dup"
      refute fingerprint =~ "alice"
    end
  end

  describe "first invalid row short-circuits (no need to scan further)" do
    test "an early valid row does not mask a later invalid row" do
      yaml = """
      bindings:
        - open_id: "ou_1"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "ou_2"
          user_uri: "not-a-valid-uri-at-all"
      """

      assert {:error, {:invalid_row, 2, _}} = Parser.parse_and_validate(yaml)
    end
  end
end
