defmodule EzagentPluginLiveview.AdminLiveMentionParseTest do
  @moduledoc """
  Regression test for the 2026-05-26 mention-parser interaction with
  mention-gated dispatch (Allen 09:27 report).

  ## The two-PR interaction Allen perceived as a cc-agent auto-spawn regression

  Two PRs each correct individually compose into a UX regression:

  1. **Phase 8b (#157, 2026-05-20)** — admin_live's chat composer
     replaced its `agent_uri` form-field dropdown with text-only
     `parse_mentions` regex (`@(entity://[^\\s]+)`). Mentions are now
     parsed from message text. Without the JS autocomplete expanding
     `@cc_e2e_final` → `@entity://system/agent/cc_e2e_final`, the
     regex finds nothing and `mentions: []`.

  2. **mention-gated dispatch (#226, 2026-05-22)** — the
     `system_default` routing rule's receivers changed from
     `[$session_members]` → `[$session_users, $mentions]`. Agent
     actuation is now mention-gated: an un-mentioned agent gets no
     `chat.receive`.

  Pre-PR-#226, an empty `mentions: []` was harmless — every member
  (including all agents) received the message via `$session_members`.
  Post-PR-#226, `mentions: []` means `$mentions` expands to nothing
  and agents are silently skipped. The cc agent's PtyServer
  (auto-spawn path) is healthy and the claude bridge is connected and
  joined to `cc:bridge:<uri>`; the bridge just never receives a
  `to_claude` push because the agent wasn't in the recipient set.

  ## What this test guards

  `AdminLive.parse_mentions/2` must accept BOTH `@entity://...` URI
  form AND a bare `@<name>` form (resolved against the in-session
  `member_options` by `display_name` and URI path segment). A bare
  name that doesn't resolve to a session member is silently dropped
  (parser tolerance — `@` is also used for human emphasis).
  """

  # team-routing-unification §3.6 (PR-6) — the legend-precedence tests seed
  # rule-set entries via RuleStore (DB), so this file uses DataCase (Repo
  # sandbox). The pure parse_mentions/2 tests are unaffected.
  use EzagentCore.DataCase, async: false

  alias EzagentPluginLiveview.AdminLive

  @cc_agent_uri "entity://system/agent/cc_e2e_final"
  @user_uri "entity://system/user/linyilun"

  defp members do
    [
      %{"uri" => @cc_agent_uri, "display_name" => "cc_e2e_final"},
      %{"uri" => @user_uri, "display_name" => "linyilun"}
    ]
  end

  describe "parse_mentions/2 — URI form (Phase 8b canonical)" do
    test "extracts an autocomplete-expanded @entity:// URI" do
      text = "@#{@cc_agent_uri} please reply"

      assert [%URI{} = uri] = AdminLive.parse_mentions(text, members())
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "URI form works even with empty members list (no fallback needed)" do
      text = "@#{@cc_agent_uri} hi"

      assert [%URI{} = uri] = AdminLive.parse_mentions(text, [])
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "dedups when URI is mentioned twice" do
      text = "@#{@cc_agent_uri} hi @#{@cc_agent_uri} again"

      assert [%URI{}] = AdminLive.parse_mentions(text, members())
    end
  end

  describe "parse_mentions/2 — bare-name fallback (Allen 2026-05-26 regression fix)" do
    test "resolves @display_name to the matching member's URI" do
      # The 09:27 e2e symptom: Allen types `@cc_e2e_final` (no
      # autocomplete). Pre-fix mentions=[] → no dispatch → no reply.
      # Post-fix the bare name resolves to the cc agent URI.
      text = "@cc_e2e_final please reply with: hello world"

      assert [%URI{} = uri] = AdminLive.parse_mentions(text, members())
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "resolves @user-name to the matching user URI" do
      text = "thanks @linyilun"

      assert [%URI{} = uri] = AdminLive.parse_mentions(text, members())
      assert URI.to_string(uri) == @user_uri
    end

    test "bare name in mid-sentence works (regex anchors on @ boundary)" do
      text = "please ask @cc_e2e_final about it"

      assert [uri] = AdminLive.parse_mentions(text, members())
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "an unresolvable bare name is silently dropped (parser tolerance)" do
      # `@unknown` is not a session member. Don't crash; just don't
      # add a phantom mention.
      text = "@unknown is not here"

      assert [] = AdminLive.parse_mentions(text, members())
    end

    test "@ in email-like context does NOT match (lookbehind on word char)" do
      # `foo@bar` is an email-like fragment; the regex `(?<![\\w])@`
      # ensures only a non-word char (start of string / space /
      # punctuation) precedes the @ for it to count as a mention.
      text = "email me at foo@cc_e2e_final.com"

      assert [] = AdminLive.parse_mentions(text, members())
    end

    test "URI form + bare form together — dedup by URI string" do
      text = "@#{@cc_agent_uri} and also @cc_e2e_final"

      assert [%URI{} = uri] = AdminLive.parse_mentions(text, members())
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "multiple distinct bare names resolve to distinct members" do
      text = "@cc_e2e_final ping @linyilun"

      uris =
        AdminLive.parse_mentions(text, members())
        |> Enum.map(&URI.to_string/1)
        |> Enum.sort()

      assert uris == Enum.sort([@cc_agent_uri, @user_uri])
    end

    test "resolves by URI path segment when display_name is the fallback" do
      # Pre-existing entities without a `entity_profiles` row use
      # `EntityPresenter.fallback/1` which returns the URI's path
      # segment. The member_options carries that as the display_name —
      # but a future change could distinguish them. Verify the URI
      # path segment also resolves so the parser keeps working even
      # if display_name and segment diverge.
      members_with_distinct_display = [
        %{"uri" => @cc_agent_uri, "display_name" => "CC E2E Agent (Final)"}
      ]

      text = "@cc_e2e_final do the thing"

      assert [uri] = AdminLive.parse_mentions(text, members_with_distinct_display)
      assert URI.to_string(uri) == @cc_agent_uri
    end
  end

  describe "parse_mentions/2 — collision + unicode boundary (codex 2026-05-26 MEDIUMs)" do
    test "URI-segment match wins over display_name collision" do
      # Two members share display_name "admin"; the agent's URI segment
      # is `evil`, the user's URI segment is `admin`. Typing `@admin`
      # MUST resolve to the user (URI segment), not the agent.
      members = [
        %{"uri" => "entity://system/agent/evil", "display_name" => "admin"},
        %{"uri" => "entity://system/user/admin", "display_name" => "admin"}
      ]

      assert [uri] = AdminLive.parse_mentions("@admin please check", members)
      assert URI.to_string(uri) == "entity://system/user/admin"
    end

    test "ambiguous bare-name with multiple URI-segment matches drops silently" do
      # Two distinct URIs share the same path segment `admin`. The
      # parser cannot disambiguate; drop rather than guess.
      members = [
        %{"uri" => "entity://system/user/admin", "display_name" => "Alice"},
        %{"uri" => "entity://team-alpha/user/admin", "display_name" => "Bob"}
      ]

      assert [] = AdminLive.parse_mentions("@admin", members)
    end

    test "ambiguous display_name with no URI-segment match drops silently" do
      # No URI-segment matches `admin`; both members carry it as
      # display_name. Same drop rule.
      members = [
        %{"uri" => "entity://system/user/u1", "display_name" => "admin"},
        %{"uri" => "entity://system/user/u2", "display_name" => "admin"}
      ]

      assert [] = AdminLive.parse_mentions("@admin", members)
    end

    test "duplicate member rows with SAME URI are not ambiguous (uniq)" do
      # A legitimate duplicate (e.g. join races / list re-fetches)
      # collapses to one URI — NOT counted as ambiguous.
      members = [
        %{"uri" => @cc_agent_uri, "display_name" => "cc_e2e_final"},
        %{"uri" => @cc_agent_uri, "display_name" => "cc_e2e_final"}
      ]

      assert [uri] = AdminLive.parse_mentions("@cc_e2e_final", members)
      assert URI.to_string(uri) == @cc_agent_uri
    end

    test "CJK character before @ does NOT count as start-of-mention boundary" do
      # Codex MEDIUM — the previous `(?<![\w])` lookbehind was ASCII;
      # `中文@cc_e2e_final` slipped through. The Unicode-aware
      # `(?<![\p{L}\p{N}_])` blocks it (parity with Latin
      # `foo@cc_e2e_final` which has always been blocked).
      assert [] = AdminLive.parse_mentions("中文@cc_e2e_final", members())
    end

    test "Hangul character before @ does NOT count as start-of-mention boundary" do
      assert [] = AdminLive.parse_mentions("한글@cc_e2e_final", members())
    end

    test "punctuation / space before @ still counts as mention boundary" do
      assert [_] = AdminLive.parse_mentions("hello @cc_e2e_final", members())
      assert [_] = AdminLive.parse_mentions("(@cc_e2e_final)", members())
      assert [_] = AdminLive.parse_mentions("。@cc_e2e_final", members())
      assert [_] = AdminLive.parse_mentions("，@cc_e2e_final", members())
    end
  end

  # team-routing-unification §3.6 (PR-6, codex-redesign) — legend precedence in
  # the LV parser. parse_mentions/3 consults the session legend registry BEFORE
  # the URI/bare member path and returns `{mentions, legend_triggers}`. A
  # `@legend` is surfaced as a SYMBOLIC NAME in `legend_triggers` (NOT
  # pre-canonicalized to URIs — the send path fires the entry rule via the
  # Resolver). The legend `@<token>` is STRIPPED from the text before concrete
  # member resolution so it can NEVER also resolve to a member (codex MED #4).
  describe "parse_mentions/3 — legend precedence (GATE b)" do
    test "a legend token surfaces as a SYMBOLIC name in legend_triggers, not mentions" do
      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      assert {[], ["传话游戏"]} = AdminLive.parse_mentions("@传话游戏 开始", members(), legends)
    end

    test "a legend wins even when a member's URI segment shares the typed token" do
      legends =
        Ezagent.Routing.Legend.put(%{}, "cc_e2e_final", member_set: [], bound_rule_set: "rs")

      # Without precedence this would resolve to the cc agent URI; the legend
      # registry intercepts it first → legend trigger, NO concrete mention.
      assert {[], ["cc_e2e_final"]} ==
               AdminLive.parse_mentions("@cc_e2e_final hi", members(), legends)
    end

    # codex 2026-06-01 MED #4 — display-name collision. The legend token is
    # stripped from the text BEFORE bare parsing, so a member whose mutable
    # `display_name` equals the legend (but whose URI segment differs) does NOT
    # get the message. The PRE-fix code only rejected resolved URIs whose URI
    # SEGMENT equaled the token, so a display-name-only collision leaked.
    test "a member whose DISPLAY_NAME (not URI segment) equals the legend does NOT leak" do
      # Member URI segment is `bob`; display_name happens to equal the legend
      # `传话游戏`. Typing `@传话游戏` must NOT resolve to bob.
      collide_members = [
        %{"uri" => "entity://system/user/bob", "display_name" => "传话游戏"}
      ]

      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      assert {[], ["传话游戏"]} =
               AdminLive.parse_mentions("@传话游戏 hi", collide_members, legends)
    end

    test "non-legend mentions still resolve to member URIs (mixed)" do
      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      {mentions, legend_triggers} =
        AdminLive.parse_mentions("@传话游戏 and @cc_e2e_final", members(), legends)

      assert legend_triggers == ["传话游戏"]
      assert Enum.any?(mentions, &(URI.to_string(&1) == @cc_agent_uri))
    end

    test "empty legends → {parse_mentions/2, []}" do
      assert AdminLive.parse_mentions("@cc_e2e_final hi", members(), %{}) ==
               {AdminLive.parse_mentions("@cc_e2e_final hi", members()), []}
    end
  end

  describe "parse_mentions/2 — defensive shapes" do
    test "non-binary text returns empty" do
      assert [] = AdminLive.parse_mentions(nil, members())
      assert [] = AdminLive.parse_mentions(123, members())
    end

    test "empty text returns empty" do
      assert [] = AdminLive.parse_mentions("", members())
    end

    test "members list with malformed entries does not crash" do
      bad_members = [
        %{"uri" => nil, "display_name" => "x"},
        %{"display_name" => "no-uri"},
        %{"uri" => @cc_agent_uri, "display_name" => "cc_e2e_final"}
      ]

      text = "@cc_e2e_final"

      assert [uri] = AdminLive.parse_mentions(text, bad_members)
      assert URI.to_string(uri) == @cc_agent_uri
    end
  end
end
