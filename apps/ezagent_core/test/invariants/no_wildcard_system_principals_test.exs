defmodule EzagentCore.Invariants.NoWildcardSystemPrincipalsTest do
  @moduledoc """
  PR-CC-2-v2 §5 — non-bootstrap system principals MUST NOT carry the
  full-wildcard cap shape in the catalog.

  The "full-wildcard" shape is `%Capability{kind: :any, behavior: :any,
  instance: :any, workspace_uri: :any}` — the structural admin
  invariant per Decision #81 + SPEC v3 §4.4. Pre-PR-CC-2-v2 (the
  PR-CC-1 bridge window) EVERY non-empty catalog entry effectively
  carried this shape via the bridge. Post-PR-CC-2-v2 the catalog
  holds STRUCTURALLY NARROW caps; `system://bootstrap` (genesis) is now
  the ONLY principal that retains the wildcard. (`system://mix-task`
  formerly also retained an operator-driven wildcard per in-VM trust
  §10.5; it was ELIMINATED 2026-06-19 — the operator CLI tasks now route
  their authority through the real `entity://system/user/admin` entity
  with an inline per-action admin cap, not the ambient wildcard.
  `system://chat-reply` formerly retained an open-plugin reply wildcard;
  it was ELIMINATED 2026-06-20, 甲-3 — each agent bridge now presents its
  OWN inline narrow `session.send` cap instead of borrowing the wildcard.
  `system://chat-router` was the LAST non-genesis wildcard holder — the
  open-plugin `chat.receive` fan-out; it was ELIMINATED 2026-06-20, 甲-4 —
  the fan-out now mints a per-recipient inline `:receive` cap from the
  recipient's own URI [member self-consent], so the "catalog cannot
  enumerate the open plugin Behavior set" rationale for the wildcard is
  moot.)

  See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §5.
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  @bootstrap_uri "system://bootstrap"

  test "non-bootstrap system principals do NOT hold wildcard caps" do
    offenders =
      for {uri, caps} <- Catalog.entries(),
          uri != @bootstrap_uri,
          Enum.any?(caps, &wildcard_cap?/1),
          do: uri

    assert offenders == [],
           "principals must not carry wildcard caps (only bootstrap may): " <>
             inspect(offenders) <>
             "\nSee SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §5."
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
