defmodule Ezagent.URITest do
  use ExUnit.Case, async: true

  describe "parse!/1" do
    test "parses 3-segment entity:// URI (SPEC v3 §3.2)" do
      uri = Ezagent.URI.parse!("entity://user/system/admin")
      assert uri.scheme == "entity"
      assert uri.host == "user"
      assert uri.path == "/system/admin"
    end

    test "parses URI with action query (SPEC v2 §5.2, PR #148)" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo-builder?action=chat.receive")
      assert uri.scheme == "entity"
      assert uri.host == "agent"
      assert uri.path == "/team-alpha/cc_demo-builder"
      assert uri.query == "action=chat.receive"
    end

    test "parses cross-workspace entity URI" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo")
      assert uri.scheme == "entity"
      assert uri.host == "agent"
      assert uri.path == "/team-alpha/cc_demo"
    end

    test "parses 3-segment session:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.parse!("session://default/system/main")
      assert uri.scheme == "session"
      assert uri.host == "default"
      assert uri.path == "/system/main"
    end

    test "parses 3-segment template:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.parse!("template://agent/system/cc-orchestrator")
      assert uri.scheme == "template"
      assert uri.host == "agent"
      assert uri.path == "/system/cc-orchestrator"
    end

    test "parses 3-segment resource:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.parse!("resource://uploads/team-alpha/file-abc")
      assert uri.scheme == "resource"
      assert uri.host == "uploads"
      assert uri.path == "/team-alpha/file-abc"
    end

    test "rejects 2-segment session:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal `session://default/system/main` — the rejected 2-seg form is the point.
      legacy = "session://default/" <> "main"

      assert_raise ArgumentError, ~r/workspace segment/, fn ->
        Ezagent.URI.parse!(legacy)
      end
    end

    test "rejects 2-segment template:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal `template://agent/team-alpha/cc-orch` — the rejected 2-seg form is the point.
      legacy = "template://agent/" <> "cc-orch"

      assert_raise ArgumentError, ~r/workspace segment/, fn ->
        Ezagent.URI.parse!(legacy)
      end
    end

    test "rejects 2-segment resource:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal `resource://uploads/default/abc` — the rejected 2-seg form is the point.
      legacy = "resource://uploads/" <> "abc"

      assert_raise ArgumentError, ~r/workspace segment/, fn ->
        Ezagent.URI.parse!(legacy)
      end
    end

    test "raises on missing scheme" do
      assert_raise ArgumentError, ~r/missing scheme/, fn ->
        Ezagent.URI.parse!("/no-scheme")
      end
    end

    test "raises on unknown scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        Ezagent.URI.parse!("http://example.com")
      end
    end

    test "rejects deleted user:// scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        # NOTE: literal `user://default/admin` — the deleted scheme is the point.
        Ezagent.URI.parse!("user" <> "://default/admin")
      end
    end

    test "rejects deleted agent:// scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        # NOTE: literal `agent://cc/demo` — the deleted scheme is the point.
        Ezagent.URI.parse!("agent" <> "://cc/demo")
      end
    end

    test "rejects 2-segment entity URI (SPEC v3 §3.2)" do
      # NOTE: literal `entity://user/admin` — the rejected 2-seg form is the point.
      legacy = "entity://user/" <> "admin"

      assert_raise ArgumentError, ~r/workspace segment/, fn ->
        Ezagent.URI.parse!(legacy)
      end
    end

    test "rejects 2-segment entity agent URI (SPEC v3 §3.2)" do
      # NOTE: literal `entity://agent/cc_demo` — the rejected 2-seg form is the point.
      legacy = "entity://agent/" <> "cc_demo"

      assert_raise ArgumentError, ~r/workspace segment/, fn ->
        Ezagent.URI.parse!(legacy)
      end
    end

    test "rejects 4+ segment entity URI (sub-resource reserved)" do
      assert_raise ArgumentError, ~r/sub-resource positions are reserved/, fn ->
        Ezagent.URI.parse!("entity://user/system/admin/extra")
      end
    end
  end

  describe "instance/1 — entity:// 3-segment authority (SPEC v3)" do
    test "entity:// strips query (SPEC v2 §5.2 — action lives in query)" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=echo.say")
      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "entity"
      assert inst.host == "agent"
      assert inst.path == "/team-alpha/echo_default"
      assert inst.query == nil
      assert URI.to_string(inst) == "entity://agent/team-alpha/echo_default"
    end

    test "entity:// already-instance form is unchanged" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo-builder")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "entity://user/system/admin is unchanged" do
      uri = Ezagent.URI.parse!("entity://user/system/admin")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "entity:// agent flavor in name prefix is opaque to parser" do
      # PR #141 SPEC v2 §5.14: <flavor>_<name> is one opaque name string.
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo-builder?action=chat.receive")
      inst = Ezagent.URI.instance(uri)
      assert URI.to_string(inst) == "entity://agent/team-alpha/cc_demo-builder"
    end
  end

  describe "instance/1 — unified 3-seg schemes (SPEC v3 §3.6 PR-7)" do
    test "session:// strips query and keeps full 3-segment path" do
      uri = Ezagent.URI.parse!("session://default/system/main?action=chat.send")
      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "session"
      assert inst.host == "default"
      assert inst.path == "/system/main"
      assert inst.query == nil
      assert URI.to_string(inst) == "session://default/system/main"
    end

    test "template:// strips query and keeps full 3-segment path" do
      uri =
        Ezagent.URI.parse!("template://agent/system/cc-orchestrator?action=identity.list_caps")

      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "template"
      assert inst.host == "agent"
      assert inst.path == "/system/cc-orchestrator"
      assert inst.query == nil
    end

    test "resource:// strips query and keeps full 3-segment path" do
      uri = Ezagent.URI.parse!("resource://uploads/default/file-abc")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "instance of workspace:// is unchanged (1-seg root scheme)" do
      uri = Ezagent.URI.parse!("workspace://team-alpha")
      assert Ezagent.URI.instance(uri) == uri
    end
  end

  describe "entity_workspace_uri/1 (SPEC v3 §3.3)" do
    test "extracts workspace URI from default-workspace user entity" do
      uri = Ezagent.URI.parse!("entity://user/team-alpha/allen")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    test "extracts workspace URI from cross-workspace agent entity" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    # Phase 9 PR-8 (SPEC v3 §13): admin lives in workspace://system.
    test "extracts workspace://system URI from admin entity" do
      uri = Ezagent.URI.parse!("entity://user/system/admin")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://system")
    end

    test "extracts workspace URI from entity URI with query string" do
      uri = Ezagent.URI.parse!("entity://user/team-alpha/allen?action=identity.list_caps")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    # V1 fix (Allen Feishu 2026-05-21) — was raising MatchError on
    # 2-segment input via the `[a, b] = String.split(...)` clause.
    # Now raises ArgumentError with a clear, actionable message
    # (defense in depth; LiveAuth's strict parse_entity_uri/1 is the
    # structural prevention).
    test "raises ArgumentError on legacy 2-segment URI (stale cookie regression)" do
      # Hand-construct the legacy shape — `parse!/1` correctly
      # rejects it at parse time, so we bypass to exercise the
      # defense-in-depth path inside entity_workspace_uri/1.
      legacy = %URI{scheme: "entity", host: "user", path: "/admin"}

      assert_raise ArgumentError, ~r/requires a 3-segment URI/, fn ->
        Ezagent.URI.entity_workspace_uri(legacy)
      end
    end

    test "raises ArgumentError mentions sign-in hint for stale cookies" do
      legacy = %URI{scheme: "entity", host: "agent", path: "/cc_demo"}

      assert_raise ArgumentError, ~r/stale session cookie/, fn ->
        Ezagent.URI.entity_workspace_uri(legacy)
      end
    end

    test "raises ArgumentError on non-entity URI struct" do
      not_entity = URI.parse("session://default/system/main")

      assert_raise ArgumentError, ~r/requires %URI\{scheme: "entity"/, fn ->
        Ezagent.URI.entity_workspace_uri(not_entity)
      end
    end

    test "raises ArgumentError on non-URI input (e.g. plain string)" do
      assert_raise ArgumentError, ~r/requires %URI/, fn ->
        Ezagent.URI.entity_workspace_uri("entity://user/team-alpha/admin")
      end
    end

    test "raises ArgumentError on path-less entity URI" do
      pathless = %URI{scheme: "entity", host: "user", path: nil}

      assert_raise ArgumentError, ~r/requires a 3-segment URI/, fn ->
        Ezagent.URI.entity_workspace_uri(pathless)
      end
    end
  end

  describe "subresource/1" do
    test "entity:// without sub-resource returns empty string" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/cc_demo-builder")
      assert Ezagent.URI.subresource(uri) == ""
    end

    test "entity:// with just /<workspace>/<name> → empty string" do
      uri = Ezagent.URI.parse!("entity://user/system/admin")
      assert Ezagent.URI.subresource(uri) == ""
    end

    test "URI with no path → empty string" do
      uri = Ezagent.URI.parse!("workspace://team-alpha")
      assert Ezagent.URI.subresource(uri) == ""
    end
  end

  describe "behavior_action/1 — query-string action parser (SPEC v2 §5.2, PR #148)" do
    test "extracts {behavior_atom, action_atom} from entity:// ?action=" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=echo.say")
      assert {:ok, {:echo, :say}} = Ezagent.URI.behavior_action(uri)
    end

    test "extracts from 3-seg session:// scheme (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.parse!("session://default/system/main?action=chat.send")
      assert {:ok, {:chat, :send}} = Ezagent.URI.behavior_action(uri)
    end

    test "extracts when behavior or action contains underscores" do
      uri = Ezagent.URI.parse!("workspace://team-alpha/main?action=routing.add_rule")
      assert {:ok, {:routing, :add_rule}} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action for URI without query" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action when query lacks action key" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?foo=bar")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action for empty action value" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :malformed_action when action lacks a dot" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=justone")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :malformed_action for empty behavior or action half" do
      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=.say")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)

      uri = Ezagent.URI.parse!("entity://agent/team-alpha/echo_default?action=echo.")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)
    end
  end
end
