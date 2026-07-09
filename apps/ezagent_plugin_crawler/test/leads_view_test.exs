defmodule EzagentPluginCrawler.LeadsViewTest do
  @moduledoc """
  段4 D2 unit gate for `EzagentPluginCrawler.LeadsView` — the crawler leads
  `Ezagent.UI.SessionView` DECLARATION（照 kanban `BoardView` 测试模具）.

  Declaration-side only: the view + its json-render tree live in the crawler
  plugin; world consumes the registry generically (world-views #1192/#1199) —
  ZERO world changes here. What this test locks:

    * the `SessionView` contract surface (id/label/icon);
    * cap-gating: `view_behavior/0 → Ezagent.ActionSet.CrawlerRender`, so
      `SessionView.authorize_view/3` requires `{Session, :crawler_render}` —
      plus the cap-only NEGATIVE: a caller with no identity is denied;
    * `applies_to?/1` is FAIL-SAFE and keyed on an installed Definition
      declaring the crawler view (a session without it → false, junk → false);
    * the external target: `external_render?/0 → true` + `external_render/1`
      delegating to the read-only leads projection.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCrawler.LeadsView

  test "CrawlerRender's literal slice key matches the Crawler state slice (drift lock)" do
    # crawler_render.ex 的 get_slice 用字面量 :crawler（sensitive_slice_read 门
    # 对非字面量键 fail-closed）；本断言锁死它与宏派生 slice 键的一致性。
    assert Ezagent.ActionSet.Crawler.state_slice() == :crawler
  end

  test "implements Ezagent.UI.SessionView with the crawler leads identity" do
    assert Enum.member?(
             LeadsView.module_info(:attributes)
             |> Keyword.get_values(:behaviour)
             |> List.flatten(),
             Ezagent.UI.SessionView
           )

    assert LeadsView.id() == :crawler_leads
    assert LeadsView.label() == "线索"
    assert is_binary(LeadsView.icon()) and LeadsView.icon() != ""
  end

  test "is cap-gated by the CrawlerRender view read ActionSet (T2-2b)" do
    assert LeadsView.view_behavior() == Ezagent.ActionSet.CrawlerRender

    # the gate has a concrete cap to check (same shape Installation mints).
    session_uri = Ezagent.URI.session("ws-lv", "generic", "s1")

    assert [%Ezagent.Capability{action: :crawler_render}] =
             Ezagent.UI.SessionView.render_needed_caps(
               Ezagent.ActionSet.CrawlerRender,
               session_uri
             )
  end

  test "cap-only NEGATIVE: authorize_view denies a caller without identity/caps" do
    session_uri = Ezagent.URI.session("ws-lv", "generic", "s2")

    # nil caller (no identity) is denied for a gated view by contract.
    refute Ezagent.UI.SessionView.authorize_view(LeadsView, nil, session_uri)

    # a real URI holding NO caps (nothing granted in this test node) is denied.
    stranger =
      Ezagent.URI.new!("entity://ws-lv/user/stranger-#{System.unique_integer([:positive])}")

    refute Ezagent.UI.SessionView.authorize_view(LeadsView, stranger, session_uri)
  end

  test "applies_to?/1 is false for a session without an installed crawler-view Definition (fail-safe)" do
    # no install rows for this session (and no DB checkout in this async test) —
    # the check must degrade to false, never raise.
    refute LeadsView.applies_to?(Ezagent.URI.session("ws-lv", "generic", "not-installed"))
  end

  test "applies_to?/1 is false for junk input (fail-safe)" do
    refute LeadsView.applies_to?(nil)
    refute LeadsView.applies_to?("not a uri")
    refute LeadsView.applies_to?(Ezagent.URI.workspace("ws-lv"))
  end

  test "declares an EXTERNAL json-render target delegating to CrawlerRender" do
    assert LeadsView.external_render?()

    # no retained leads on this session → nil (nothing to render externally
    # yet), per the SessionView external_render/1 contract; junk input → nil.
    assert LeadsView.external_render(Ezagent.URI.session("ws-lv-none", "generic", "s3")) == nil
    assert LeadsView.external_render(nil) == nil
  end
end
