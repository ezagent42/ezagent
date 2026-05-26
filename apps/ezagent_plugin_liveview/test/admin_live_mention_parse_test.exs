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
     `@cc_e2e_final` → `@entity://agent/system/cc_e2e_final`, the
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

  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.AdminLive

  @cc_agent_uri "entity://agent/system/cc_e2e_final"
  @user_uri "entity://user/system/linyilun"

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
        %{"uri" => "entity://agent/system/evil", "display_name" => "admin"},
        %{"uri" => "entity://user/system/admin", "display_name" => "admin"}
      ]

      assert [uri] = AdminLive.parse_mentions("@admin please check", members)
      assert URI.to_string(uri) == "entity://user/system/admin"
    end

    test "ambiguous bare-name with multiple URI-segment matches drops silently" do
      # Two distinct URIs share the same path segment `admin`. The
      # parser cannot disambiguate; drop rather than guess.
      members = [
        %{"uri" => "entity://user/system/admin", "display_name" => "Alice"},
        %{"uri" => "entity://user/team-alpha/admin", "display_name" => "Bob"}
      ]

      assert [] = AdminLive.parse_mentions("@admin", members)
    end

    test "ambiguous display_name with no URI-segment match drops silently" do
      # No URI-segment matches `admin`; both members carry it as
      # display_name. Same drop rule.
      members = [
        %{"uri" => "entity://user/system/u1", "display_name" => "admin"},
        %{"uri" => "entity://user/system/u2", "display_name" => "admin"}
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
