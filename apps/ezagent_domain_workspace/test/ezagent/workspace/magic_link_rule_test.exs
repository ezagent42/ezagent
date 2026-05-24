defmodule Ezagent.Workspace.MagicLinkRuleTest do
  @moduledoc """
  SPEC 2026-05-24 v2 PR-A — workspace-scoped magic-link rules.

  Asserts the contract:
  - `add/3` validates rule_type
  - `accepts_email?/2` OR-combines all rules on a workspace
  - case-insensitive on email + domain
  - reverse lookup `workspaces_accepting/1` returns matching ws URIs
  - `delete_all_for/1` cascade-cleanup
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.MagicLinkRule

  defp uniq, do: System.unique_integer([:positive])

  defp ws_uri(name), do: "workspace://#{name}-#{uniq()}"

  describe "add/3" do
    test "inserts a domain rule (lowercased)" do
      ws = ws_uri("ws-add-domain")

      assert {:ok, rule} = MagicLinkRule.add(ws, "domain", "H2OSLabs.COM")
      assert rule.rule_type == "domain"
      assert rule.rule_value == "h2oslabs.com"
      assert rule.workspace_uri == ws
    end

    test "inserts a user_list rule (lowercased)" do
      ws = ws_uri("ws-add-user")

      assert {:ok, rule} = MagicLinkRule.add(ws, "user_list", "  Alice@Example.COM  ")
      assert rule.rule_value == "alice@example.com"
    end

    test "rejects invalid rule_type" do
      assert {:error, {:invalid_rule_type, "wat"}} =
               MagicLinkRule.add("workspace://x", "wat", "anything")
    end

    test "rejects empty rule_value" do
      assert {:error, :invalid_args} = MagicLinkRule.add("workspace://x", "domain", "")
    end
  end

  describe "accepts_email?/2 — domain rule" do
    setup do
      ws = ws_uri("h2oslabs")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "h2oslabs.com")
      %{ws: ws}
    end

    test "matches lowercased email at the domain", %{ws: ws} do
      assert MagicLinkRule.accepts_email?(ws, "alice@h2oslabs.com") == true
      assert MagicLinkRule.accepts_email?(ws, "ALICE@H2OSLABS.com") == true
    end

    test "rejects mismatched domains", %{ws: ws} do
      assert MagicLinkRule.accepts_email?(ws, "alice@other.com") == false
    end

    test "rejects non-emails", %{ws: ws} do
      assert MagicLinkRule.accepts_email?(ws, "notanemail") == false
    end
  end

  describe "accepts_email?/2 — user_list rule" do
    setup do
      ws = ws_uri("special")
      {:ok, _} = MagicLinkRule.add(ws, "user_list", "alice@anywhere.com")
      {:ok, _} = MagicLinkRule.add(ws, "user_list", "bob@elsewhere.com")
      %{ws: ws}
    end

    test "matches exact email", %{ws: ws} do
      assert MagicLinkRule.accepts_email?(ws, "alice@anywhere.com") == true
      assert MagicLinkRule.accepts_email?(ws, "Bob@Elsewhere.COM") == true
    end

    test "does NOT match domain (a user_list rule is per-email, not per-domain)", %{ws: ws} do
      assert MagicLinkRule.accepts_email?(ws, "charlie@anywhere.com") == false
    end
  end

  describe "accepts_email?/2 — OR-combined" do
    test "matches if ANY rule on the workspace matches" do
      ws = ws_uri("multi")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "h2oslabs.com")
      {:ok, _} = MagicLinkRule.add(ws, "user_list", "external@partner.io")

      assert MagicLinkRule.accepts_email?(ws, "alice@h2oslabs.com") == true
      assert MagicLinkRule.accepts_email?(ws, "external@partner.io") == true
      assert MagicLinkRule.accepts_email?(ws, "random@nowhere.org") == false
    end
  end

  describe "workspaces_accepting/1 — reverse lookup" do
    test "returns all workspace URIs whose rules accept the email" do
      ws_a = ws_uri("acme")
      ws_b = ws_uri("bigco")
      {:ok, _} = MagicLinkRule.add(ws_a, "domain", "acme.com")
      {:ok, _} = MagicLinkRule.add(ws_b, "user_list", "alice@acme.com")

      matches = MagicLinkRule.workspaces_accepting("alice@acme.com")
      assert ws_a in matches
      assert ws_b in matches
      assert length(matches) == 2
    end

    test "returns [] when no workspace accepts" do
      assert MagicLinkRule.workspaces_accepting("nobody@nowhere.org") == []
    end

    test "deduplicates when same workspace has multiple matching rules" do
      ws = ws_uri("dup")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "acme.com")
      {:ok, _} = MagicLinkRule.add(ws, "user_list", "alice@acme.com")

      matches = MagicLinkRule.workspaces_accepting("alice@acme.com")
      assert matches == [ws]
    end
  end

  describe "list_for/1" do
    test "returns all rules for a workspace, ordered by id" do
      ws = ws_uri("listed")
      {:ok, r1} = MagicLinkRule.add(ws, "domain", "d1.com")
      {:ok, r2} = MagicLinkRule.add(ws, "user_list", "u@d2.com")

      ids = MagicLinkRule.list_for(ws) |> Enum.map(& &1.id)
      assert ids == [r1.id, r2.id]
    end

    test "scope to one workspace (no cross-pollination)" do
      ws_a = ws_uri("scope-a")
      ws_b = ws_uri("scope-b")
      {:ok, _} = MagicLinkRule.add(ws_a, "domain", "a.com")
      {:ok, _} = MagicLinkRule.add(ws_b, "domain", "b.com")

      assert [%{rule_value: "a.com"}] = MagicLinkRule.list_for(ws_a)
      assert [%{rule_value: "b.com"}] = MagicLinkRule.list_for(ws_b)
    end
  end

  describe "delete + delete_all_for" do
    test "delete/1 removes a single rule by id" do
      ws = ws_uri("del-one")
      {:ok, rule} = MagicLinkRule.add(ws, "domain", "x.com")

      assert :ok = MagicLinkRule.delete(rule.id)
      assert MagicLinkRule.list_for(ws) == []
    end

    test "delete/1 is idempotent on missing id" do
      assert :ok = MagicLinkRule.delete(99_999_999)
    end

    test "delete_all_for/1 cleans up workspace rules" do
      ws = ws_uri("del-all")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "x.com")
      {:ok, _} = MagicLinkRule.add(ws, "user_list", "y@x.com")

      assert :ok = MagicLinkRule.delete_all_for(ws)
      assert MagicLinkRule.list_for(ws) == []
    end
  end

  describe "invite_only — codex PR-A round-1 HIGH-2 (Allen 2026-05-24)" do
    # Pre-fix bug: `accepts_email?` treated `invite_only` like
    # `user_list`, so a stored `invite_only` row was a silent
    # allowlist bypass. Post-fix: invite_only is RESERVED — it can
    # be stored, but `accepts_email?` and `workspaces_accepting`
    # ignore it. PR-D will add the token-gate verification path.

    test "accepts_email?/2 does NOT grant access via an invite_only row" do
      ws = ws_uri("invite-bypass-test")
      {:ok, _} = MagicLinkRule.add(ws, "invite_only", "victim@example.com")

      refute MagicLinkRule.accepts_email?(ws, "victim@example.com"),
             "invite_only must NOT grant bare email access — PR-D adds the token gate"
    end

    test "workspaces_accepting/1 EXCLUDES invite_only matches" do
      ws = ws_uri("invite-onboarding-test")
      {:ok, _} = MagicLinkRule.add(ws, "invite_only", "victim@example.com")

      matches = MagicLinkRule.workspaces_accepting("victim@example.com")

      refute ws in matches,
             "invite_only must not surface as a 'joinable' workspace in onboarding"
    end

    test "invite_only coexists peacefully with other rules on the same workspace" do
      ws = ws_uri("invite-mixed")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "good.com")
      {:ok, _} = MagicLinkRule.add(ws, "invite_only", "pending@good.com")

      # Domain rule grants access (matches @good.com)
      assert MagicLinkRule.accepts_email?(ws, "pending@good.com") == true

      # If domain rule didn't exist, invite_only alone wouldn't grant
      ws2 = ws_uri("invite-mixed-2")
      {:ok, _} = MagicLinkRule.add(ws2, "invite_only", "pending@nowhere.test")

      refute MagicLinkRule.accepts_email?(ws2, "pending@nowhere.test")
    end
  end

  describe "Ezagent.Workspace facade" do
    test "any_workspace_accepts?/1 OR-checks across workspaces" do
      ws_a = ws_uri("facade-a")
      {:ok, _} = MagicLinkRule.add(ws_a, "domain", "facade.test")

      assert Ezagent.Workspace.any_workspace_accepts?("alice@facade.test") == true
      assert Ezagent.Workspace.any_workspace_accepts?("nope@nowhere.org") == false
    end

    test "accepts_email?/2 checks a specific workspace" do
      ws = ws_uri("facade-specific")
      {:ok, _} = MagicLinkRule.add(ws, "domain", "specific.test")

      assert Ezagent.Workspace.accepts_email?(ws, "alice@specific.test") == true
      assert Ezagent.Workspace.accepts_email?(ws, "alice@other.test") == false
    end
  end
end
