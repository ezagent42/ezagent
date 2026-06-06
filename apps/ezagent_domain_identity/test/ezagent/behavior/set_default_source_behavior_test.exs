defmodule Ezagent.Credential.SetDefaultSourceBehaviorTest do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2, codex CRIT) — the cap-checked + audited write chokepoint
  for the user default-credential-source pointer.

  Exercises the AUTHORIZED path end-to-end through `Ezagent.Router.dispatch` (via
  `Ezagent.Credential.UserDefaultSource.set_via_dispatch/3`):

    - owner (holding the `:set_default_credential_source` cap on their own User Kind)
      can set the pointer → `{:ok, _}` and the pointer is persisted;
    - a stranger with unrelated caps is denied `:unauthorized` by CapBAC (no bypass);
    - a successful dispatch records an audit (invocation) row for the action.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Credential.UserDefaultSource, as: UDS
  alias Ezagent.Users

  @ws "team-a"

  defp seed_agent(uri_str, owner, flavor) do
    {:ok, _} = Ezagent.SnapshotStore.write(uri_str, %{}, kind_type: :agent)
    uri = Ezagent.URI.new!(uri_str)
    :ok = Ezagent.AgentLineage.record(uri, owner)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, flavor)
    uri_str
  end

  # The cap an owner holds on their own User Kind to set their default source.
  defp set_cap(owner_uri) do
    %Capability{
      kind: :user,
      behavior: Ezagent.Behavior.UserDefaultCredentialSource,
      action: :set_default_credential_source,
      instance: Ezagent.URI.instance(owner_uri),
      workspace_uri: Capability.workspace_of(owner_uri),
      granted_by: Ezagent.URI.new!("entity://system/user/admin"),
      granted_at: ~U[2026-06-06 00:00:00Z]
    }
  end

  setup do
    suffix = System.unique_integer([:positive])
    owner_uri = Ezagent.URI.new!("entity://#{@ws}/user/alice#{suffix}")
    owner_str = URI.to_string(owner_uri)

    source = seed_agent("entity://#{@ws}/agent/alice-base-#{suffix}", owner_str, "cc")

    {:ok, _} = Users.create(owner_str, "pw-not-secret", [set_cap(owner_uri)])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner_uri)

    {:ok, owner_uri: owner_uri, owner_str: owner_str, source: source}
  end

  test "owner can set the default source; pointer is persisted", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    assert {:ok, %{source_uri: src}} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: ctx.source, workspace: @ws},
               %{caller: ctx.owner_uri, caps: owner_caps}
             )

    assert src == ctx.source
    assert UDS.resolve(ctx.owner_str, @ws, "cc") == ctx.source
  end

  test "a stranger with unrelated caps is denied :unauthorized (no bypass)", ctx do
    stranger = Ezagent.URI.new!("entity://#{@ws}/user/eve")
    stranger_caps = MapSet.new()

    assert {:error, :unauthorized} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: ctx.source, workspace: @ws},
               %{caller: stranger, caps: stranger_caps}
             )

    # No pointer written.
    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "a successful dispatch records an audit (invocation) row for the action", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    {:ok, _} =
      UDS.set_via_dispatch(
        ctx.owner_uri,
        %{flavor: "cc", source_uri: ctx.source, workspace: @ws},
        %{caller: ctx.owner_uri, caps: owner_caps}
      )

    rows = Ezagent.EventLog.stream_by_aggregate(ctx.owner_uri)

    # The handler emits a `default_credential_source_set` audit event (the {:emit, ...}
    # effect the dispatch path persists) carrying the owner/workspace/flavor/source.
    assert Enum.any?(rows, fn r ->
             to_string(r.event_name) == "default_credential_source_set" and
               r.payload["source_uri"] == ctx.source
           end),
           "expected a default_credential_source_set audit event, got: " <>
             inspect(Enum.map(rows, & &1.event_name))
  end
end
