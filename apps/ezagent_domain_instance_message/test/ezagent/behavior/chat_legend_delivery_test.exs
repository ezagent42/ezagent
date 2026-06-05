defmodule Ezagent.Behavior.ChatLegendDeliveryTest do
  @moduledoc """
  team-routing-unification §3.6 (PR-6, codex-redesign) — proves the REDESIGNED
  legend resolution path end-to-end at the routing+delivery seam (no DB / no
  live Session Kind):

    1. A `@legend`-triggered message carries the symbolic legend NAME in the
       VIRTUAL `Message.legend_triggers` (NOT `:mentions` — a CJK name can't be
       cast to a URI).
    2. The legend's bound rule-set ENTRY rule (`mention(<legend_name>)`) fires
       through the NORMAL `Resolver.resolve_with_ctx/4` expansion — yielding
       `[{receiver_uri, matched_rule_ctx}]` where `ctx` carries the entry's
       `prompt_template_ref` AND magic receivers (`$session_members`) are
       expanded by the Resolver.
    3. `Chat.render_for_delivery/4` applies that ctx's template, so the receiver
       gets the TEMPLATED payload — not the raw message.

  This is the codex BLOCKER #1 acceptance: matched-rule ctx is NOT dropped and
  magic receivers expand, with the prompt-template applied at delivery.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Routing.{Matcher, Resolver}

  setup do
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    :ok
  end

  # Declare an isolated RoutingRegistry table holding `entries` and point the
  # Resolver at it. `entries` are `{matcher, value}` pairs in the
  # `RuleStore.load_into_registry/1` value shape.
  defp install_table(entries) do
    table = String.to_atom("legend_delivery_#{System.unique_integer([:positive])}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    Enum.each(entries, fn {matcher, value} ->
      :ok = RoutingRegistry.put(table, matcher, value)
    end)

    Application.put_env(:ezagent_core, :routing_tables, [table])
    :ok
  end

  defp entry_value(receivers, prompt_template_ref, rule_set) do
    %{
      receivers: receivers,
      applies_to_users: [],
      workspace_uri: nil,
      rule_id: System.unique_integer([:positive]),
      rule_set: rule_set,
      prompt_template_ref: prompt_template_ref
    }
  end

  test "a legend-triggered delivery carries the entry's prompt_template_ref (templated payload)" do
    session = URI.new!("session://team/default/s1")
    relay = "entity://team/agent/cc_relay"

    install_table([
      {Matcher.mention("传话游戏"), entry_value([relay], "telephone_hop", "telephone")}
    ])

    templates = %{"telephone_hop" => "接龙：{body}（by {sender}）"}

    msg =
      Message.new(
        URI.new!("entity://team/user/operator"),
        %{text: "山顶的雪化了", attachments: []},
        legend_triggers: ["传话游戏"]
      )

    # Symbolic legend name never lands in mentions.
    assert msg.mentions == []

    # The entry rule fires via the NORMAL Resolver, carrying ctx.
    assert [{%URI{} = recipient, ctx}] = Resolver.resolve_with_ctx(msg, session, [], [])
    assert URI.to_string(recipient) == relay
    assert ctx.prompt_template_ref == "telephone_hop"

    # The per-recipient delivery applies the entry's template → templated body.
    delivered = Chat.render_for_delivery(msg, ctx, templates, session)
    assert delivered.body.text == "接龙：山顶的雪化了（by entity://team/user/operator）"
    # identity preserved
    assert delivered.sender == msg.sender
  end

  test "a legend entry with a magic receiver ($session_members) fans out + carries ctx" do
    session = URI.new!("session://team/default/s1")
    cc = URI.new!("entity://team/agent/cc_a")
    codex = URI.new!("entity://team/agent/codex_b")
    sender = URI.new!("entity://team/user/operator")

    install_table([
      {Matcher.mention("broadcast"), entry_value(["$session_members"], "bcast_tpl", nil)}
    ])

    msg = Message.new(sender, %{text: "hi", attachments: []}, legend_triggers: ["broadcast"])

    pairs = Resolver.resolve_with_ctx(msg, session, [cc, codex, sender], [])

    recipients = pairs |> Enum.map(fn {u, _} -> URI.to_string(u) end) |> Enum.sort()
    assert recipients == Enum.sort([URI.to_string(cc), URI.to_string(codex)])

    # Each fanned-out recipient carries the entry's ctx (template ref intact).
    assert Enum.all?(pairs, fn {_u, ctx} -> ctx.prompt_template_ref == "bcast_tpl" end)
  end
end
