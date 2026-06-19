defmodule EzagentCore.Invariants.NoWildcardSystemPrincipalsTest do
  @moduledoc """
  PR-CC-2-v2 §5 — non-bootstrap system principals MUST NOT carry the
  full-wildcard cap shape in the catalog.

  The "full-wildcard" shape is `%Capability{kind: :any, behavior: :any,
  instance: :any, workspace_uri: :any}` — the structural admin
  invariant per Decision #81 + SPEC v3 §4.4. Pre-PR-CC-2-v2 (the
  PR-CC-1 bridge window) EVERY non-empty catalog entry effectively
  carried this shape via the bridge. Post-PR-CC-2-v2 the catalog
  holds STRUCTURALLY NARROW caps; only `system://bootstrap` (genesis)
  and the open-plugin chat fan-out principal `system://chat-router`
  retain wildcards. (`system://mix-task` formerly also retained an
  operator-driven wildcard per in-VM trust §10.5; it was ELIMINATED
  2026-06-19 — the operator CLI tasks now route their authority through
  the real `entity://system/user/admin` entity with an inline per-action
  admin cap, not the ambient wildcard. `system://chat-reply` formerly
  retained an open-plugin reply wildcard; it was ELIMINATED 2026-06-20,
  甲-3 — each agent bridge now presents its OWN inline narrow
  `session.send` cap instead of borrowing the wildcard.)

  See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §5.
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  @bootstrap_uri "system://bootstrap"
  # Open-plugin fan-out principal — chat-router fans `chat.receive` out
  # to whichever Behavior is BehaviorRegistry-registered on the recipient
  # Kind for the `:receive` action. That set is open across plugins (Echo,
  # NpAgent, future plugin Behaviors); the catalog cannot enumerate every
  # plugin's required_caps[:receive]. The wildcard cap is therefore the
  # STRUCTURAL right shape — the same admin-equivalent authority the
  # bootstrap-wildcard bridge granted, but now narrowed to just the
  # principals that legitimately need it (pathology-B follow-up to
  # PR-CC-2-v2). See Catalog.entries/0 for the inline rationale.
  #
  # (`system://chat-reply` was a sibling reply fan-out wildcard; it was
  # ELIMINATED 2026-06-20, 甲-3 — the 5 agent bridges' reply path is a
  # single concrete `session.send`, so each now presents its OWN inline
  # narrow `session.send` cap instead of borrowing this wildcard.)
  @chat_router_uri "system://chat-router"

  test "non-bootstrap, non-chat-fanout system principals do NOT hold wildcard caps" do
    offenders =
      for {uri, caps} <- Catalog.entries(),
          uri != @bootstrap_uri,
          uri != @chat_router_uri,
          Enum.any?(caps, &wildcard_cap?/1),
          do: uri

    assert offenders == [],
           "principals must not carry wildcard caps (only bootstrap + chat-router may): " <>
             inspect(offenders) <>
             "\nSee SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §5."
  end

  test "chat-router holds the wildcard cap (open-plugin fan-out structural)" do
    {_uri, caps} =
      Enum.find(Catalog.entries(), fn {uri, _} -> uri == @chat_router_uri end)

    assert Enum.any?(caps, &wildcard_cap?/1),
           "system://chat-router must hold the wildcard cap (open-plugin :receive fan-out)"
  end

  test "system://bootstrap holds exactly the wildcard cap" do
    {_uri, caps} =
      Enum.find(Catalog.entries(), fn {uri, _} -> uri == @bootstrap_uri end)

    assert Enum.any?(caps, &wildcard_cap?/1),
           "system://bootstrap must hold the wildcard cap (Decision #81 admin invariant)"
  end

  test "system://lv-anon-mount carries empty cap list" do
    {_uri, caps} =
      Enum.find(Catalog.entries(), fn {uri, _} -> uri == "system://lv-anon-mount" end)

    assert caps == [],
           "system://lv-anon-mount must carry NO caps so the auth bug surfaces (SPEC §4.4)"
  end

  defp wildcard_cap?(%Ezagent.Capability{
         kind: :any,
         behavior: :any,
         instance: :any,
         workspace_uri: :any
       }),
       do: true

  defp wildcard_cap?(%Ezagent.Capability{}), do: false
end
