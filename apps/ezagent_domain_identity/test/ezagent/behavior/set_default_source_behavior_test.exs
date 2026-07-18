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

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

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
    cap = %Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.UserDefaultCredentialSource,
      action: :set_default_credential_source,
      instance: Ezagent.URI.instance(owner_uri),
      workspace_uri: Capability.workspace_of(owner_uri),
      granted_by: Ezagent.URI.new!("entity://system/user/admin"),
      granted_at: ~U[2026-06-06 00:00:00Z]
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(owner_uri, :user)

    authority_signed_cap_as!(
      authority,
      Ezagent.Entity.User.admin_uri(),
      owner_uri,
      cap
    )
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

  test "a stranger with unrelated caps is denied :missing_cap (no bypass)", ctx do
    stranger = Ezagent.URI.new!("entity://#{@ws}/user/eve")
    stranger_caps = MapSet.new()

    assert {:error, :missing_cap} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: ctx.source, workspace: @ws},
               %{caller: stranger, caps: stranger_caps}
             )

    # No pointer written.
    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "owner_uri arg tampering cannot redirect the write to a victim (codex H1)", ctx do
    # Caller is authorized for target X (alice). The dispatch crafts an args map that
    # smuggles owner_uri = Y (bob, a different valid user) — the pre-H1 handler trusted
    # this arg and would have written Y's pointer using X's authorization.
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    victim = Ezagent.URI.new!("entity://#{@ws}/user/bob-victim")
    victim_str = URI.to_string(victim)
    # A source legitimately owned by the victim, so a tampered write would otherwise
    # pass the owner-match validation against Y.
    victim_source =
      seed_agent("entity://#{@ws}/agent/bob-victim-base", victim_str, "cc")

    target =
      Ezagent.URI.with_action(
        ctx.owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    cmd =
      Ezagent.Cmd.new(
        target,
        :set_default_credential_source,
        # Authorization is against X (alice); owner_uri smuggles Y (bob).
        %{
          flavor: "cc",
          source_uri: victim_source,
          workspace: @ws,
          owner_uri: victim_str
        },
        %{mode: :call, caller: ctx.owner_uri, caps: owner_caps, reply: {:caller_inbox, self()}}
      )

    result = Ezagent.Router.dispatch(cmd)

    # The victim's pointer MUST be untouched regardless of outcome.
    assert UDS.resolve(victim_str, @ws, "cc") == nil,
           "owner_uri arg tampering wrote the victim's pointer — H1 not fixed"

    case result do
      {:ok, _} ->
        # If the write is accepted, it MUST have been derived from the dispatched
        # target X — never the smuggled Y. X's source (alice-base) was not the
        # victim source, so resolving X for cc must NOT be the victim source.
        refute UDS.resolve(ctx.owner_str, @ws, "cc") == victim_source

      {:error, _} ->
        # Rejecting the mismatched owner_uri is also acceptable (and preferred).
        :ok
    end
  end

  # The four cross-source validations now run INSIDE this cap-checked handler (codex H2 —
  # they used to live in the core store's `persist_validated/5`). Exercise them through
  # the AUTHORIZED dispatch path so the validation body is covered where it now lives.
  test "rejects a source owned by another user in the same workspace (codex H4)", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)
    # A source in the same workspace but owned by someone else.
    bob_source =
      seed_agent(
        "entity://#{@ws}/agent/bob-other-#{System.unique_integer([:positive])}",
        "entity://#{@ws}/user/bob-other",
        "cc"
      )

    assert {:error, :source_owner_mismatch} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: bob_source, workspace: @ws},
               %{caller: ctx.owner_uri, caps: owner_caps}
             )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "rejects a source of the wrong flavor", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    codex_source =
      seed_agent(
        "entity://#{@ws}/agent/alice-codex-#{System.unique_integer([:positive])}",
        ctx.owner_str,
        "codex"
      )

    assert {:error, :source_flavor_mismatch} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: codex_source, workspace: @ws},
               %{caller: ctx.owner_uri, caps: owner_caps}
             )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "rejects a cross-workspace source", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    # Owned by alice but living in a different workspace → workspace check fires.
    other_ws_source =
      seed_agent(
        "entity://team-b/agent/alice-elsewhere-#{System.unique_integer([:positive])}",
        ctx.owner_str,
        "cc"
      )

    assert {:error, :source_workspace_mismatch} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: other_ws_source, workspace: @ws},
               %{caller: ctx.owner_uri, caps: owner_caps}
             )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "rejects a non-existent source", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    assert {:error, :source_not_found} =
             UDS.set_via_dispatch(
               ctx.owner_uri,
               %{flavor: "cc", source_uri: "entity://#{@ws}/agent/ghost", workspace: @ws},
               %{caller: ctx.owner_uri, caps: owner_caps}
             )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == nil
  end

  test "valid re-set upserts (unique per owner/ws/flavor)", ctx do
    owner_caps = Ezagent.Identity.list_caps_for(ctx.owner_uri)

    src2 =
      seed_agent(
        "entity://#{@ws}/agent/alice-base2-#{System.unique_integer([:positive])}",
        ctx.owner_str,
        "cc"
      )

    {:ok, _} =
      UDS.set_via_dispatch(
        ctx.owner_uri,
        %{flavor: "cc", source_uri: ctx.source, workspace: @ws},
        %{caller: ctx.owner_uri, caps: owner_caps}
      )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == ctx.source

    {:ok, _} =
      UDS.set_via_dispatch(
        ctx.owner_uri,
        %{flavor: "cc", source_uri: src2, workspace: @ws},
        %{caller: ctx.owner_uri, caps: owner_caps}
      )

    assert UDS.resolve(ctx.owner_str, @ws, "cc") == src2
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
