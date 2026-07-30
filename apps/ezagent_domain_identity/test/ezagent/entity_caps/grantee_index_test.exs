defmodule Ezagent.EntityCaps.GranteeIndexTest do
  @moduledoc """
  URI-share (A2-2) — the reverse cap index `grantees_of`.

  A projection of "who currently holds a cap toward target T", derived IN the
  authoritative `EntityCaps.Store` write transaction (codex ⓪ — the single
  confluence of every conferral path, including the AGENT authoritative write that
  bypassed the old `persist_entity_caps` funnel), authorized by a PRESENTED
  unforgeable cap witness (codex ②), and filtered at read by the target's current
  authority generation AND the grantee's own identity lifecycle (codex ④).
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4, self_license_cap!: 2]

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.{GranteeIndex, Store}

  @workspace URI.new!("workspace://team-alpha")
  @issuer URI.new!("entity://team-alpha/user/issuer")
  @admin Ezagent.URI.user(:system, :admin)

  # ⓪ MERGE-GATE red-check: an AGENT's authoritative durable write goes through
  # `Store` (the path the old `persist_entity_caps` hook — `else -> :ok` for
  # non-users — MISSED). Proving: before the store write the grantee is NOT in the
  # index; after it IS.
  test "⓪ an agent's cap becomes visible ONLY via the Store write hook (miss→hit)" do
    t = target("zero")
    g = active_agent("agent")

    # Before any cap toward t: not indexed.
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == []

    grant_via_store!(t, g, :example, :send)

    # After the authoritative Store write: indexed (the agent path is covered).
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == [g]
  end

  # ② MERGE-GATE red-check: authorization is a PRESENTED cap witness, not a named
  # URI. Naming the canonical admin without PRESENTING admin caps enumerates
  # nothing; presenting the real admin caps does.
  test "② naming user://system/admin without presenting admin caps is REFUSED" do
    t = target("two")
    g = active_agent("member")
    grant_via_store!(t, g, :example, :send)

    # Impostor: names @admin but presents EMPTY caps → fail-closed.
    assert GranteeIndex.grantees_of(t, @admin, MapSet.new()) == []

    # A caller presenting caps that don't manage t → also nothing.
    assert GranteeIndex.grantees_of(t, @admin, MapSet.new([unrelated_cap()])) == []

    # The real admin, presenting its actual signed admin caps → authorized.
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == [g]
  end

  test "generation bump (regenesis) auto-invalidates stale rows without deleting" do
    t = target("gen")
    g = active_agent("holder")
    grant_via_store!(t, g, :example, :send)
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == [g]

    assert {:ok, _authority} = Ezagent.Cap.Authority.regenesis(t, :session)
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == []
  end

  # ④a: an offboarded/tombstoned grantee drops out even before the target rotates.
  test "④ a tombstoned grantee is filtered out of grantees_of" do
    t = target("life")
    g = active_agent("leaver")
    grant_via_store!(t, g, :example, :send)
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == [g]

    :ok = Store.tombstone(g)
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == []
  end

  # ⑤: a concrete-instance cap carrying a `:any` workspace_uri must NOT crash
  # reindex (the old FunctionClauseError was swallowed → silent stale index).
  test "⑤ a cap with :any workspace_uri still indexes (no silent reindex no-op)" do
    t = target("any")
    g = active_agent("anyws")

    signed = sign_cap(t, g, :example, :send, :any)
    persist_with!(g, [signed])

    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == [g]
  end

  test "behavior filter narrows to the exact behavior axis" do
    t = target("beh")
    g = active_agent("bee")
    grant_via_store!(t, g, :example, :send)

    assert GranteeIndex.grantees_of(t, @admin, admin_caps(), :example) == [g]
    assert GranteeIndex.grantees_of(t, @admin, admin_caps(), :other) == []
  end

  # canary cutover-backfill rehearsal catch #3 (#189): a pre-#1399 legacy cap is
  # a struct-shaped map that MATCHES `%Capability{}` yet LACKS the cap-signing
  # trio (signature/key_id/grantee_uri, 2026-07-14). `reindex_in_txn`'s
  # `row_attrs/2` did a strict `cap.key_id` read → `(KeyError) key :key_id not
  # found`; because reindex runs INSIDE the Store write transaction WITHOUT a
  # rescue, the whole cutover backfill rolled back and the epoch refused to
  # activate. The same crash the canary hit on byte-copied stable data.
  test "a legacy signature-less cap reindexes without KeyError and its nil-key row is fail-closed excluded" do
    t = target("legacy-reindex")
    g = active_agent("legacy-holder")

    # A properly SIGNED cap toward t, stripped of the #1399 trio → the exact
    # struct-shaped map `binary_to_term` reconstructs from a pre-signing snapshot.
    # Concrete `%URI{}` instance, so it reaches the crashing concrete-target
    # `row_attrs/2` clause (not the `:any` / scope-tuple no-op sink).
    legacy = legacy_unsigned(sign_cap(t, g, :example, :send, @workspace))
    refute Map.has_key?(legacy, :key_id)

    # FAIL-BEFORE: `Store.persist` → `reindex_in_txn` → `row_attrs` raised
    # `(KeyError) key :key_id not found`, rolling back the whole authoritative
    # write. PASS-AFTER: it completes — the legacy cap normalizes to `key_id: nil`.
    persist_with!(g, [legacy])

    # The legacy cap's reverse row IS written (not silently skipped), carrying a
    # nil key_id (the `fill_defaults` default — no signature/key_id fabricated).
    target_key = Ezagent.URI.stable_key(t)
    grantee_key = Ezagent.URI.stable_key(g)

    legacy_rows =
      Repo.all(
        from(r in GranteeIndex,
          where: r.grantee_uri == ^grantee_key and r.target_uri == ^target_key
        )
      )

    assert [%GranteeIndex{key_id: nil}] = legacy_rows

    # FAIL-CLOSED: an UNSIGNED legacy cap is not an active holder. The target's
    # active-authority generation is a concrete (non-nil) key_id, so the read
    # filter `r.key_id == ^active_key` naturally EXCLUDES the nil-key row — the
    # same fail-closed treatment a revoked/regenesis'd cap gets.
    assert GranteeIndex.grantees_of(t, @admin, admin_caps()) == []
  end

  # --- fixtures -------------------------------------------------------------

  # Strip the #1399 cap-signing trio's keys to reproduce a pre-signing
  # `binary_to_term`'d snapshot cap: a struct-shaped map that MATCHES
  # `%Capability{}` (only `:__struct__` checked) yet lacks those keys.
  defp legacy_unsigned(%Capability{} = cap),
    do: Map.drop(cap, [:signature, :key_id, :grantee_uri])

  defp u, do: System.unique_integer([:positive])

  defp target(suffix) do
    uri = Ezagent.URI.new!("session://team-alpha/boards/#{suffix}-#{u()}")
    {:ok, _authority} = Ezagent.Cap.Authority.open(uri, :session)
    uri
  end

  # An agent-typed grantee URI. It becomes `active` in the store only once
  # `persist_with!/2` writes a valid self-license alongside its caps (the store's
  # `licensed_under_lock?` gate) — no Kind spawn needed, the store row is created
  # on first `persist`.
  defp active_agent(name), do: Ezagent.URI.new!("entity://team-alpha/agent/#{name}-#{u()}")

  # The admin witness a caller PRESENTS (codex ②): the bootstrap wildcard cap
  # (`holds_admin_caps?`), as an authenticated dispatch ctx would carry it. The
  # point under test is the AUTHORIZATION logic — present an admin cap ⇒ allowed;
  # merely NAME the admin URI with no such cap ⇒ refused (the closed hole).
  defp admin_caps do
    MapSet.new([
      %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @admin,
        granted_at: DateTime.utc_now()
      }
    ])
  end

  defp unrelated_cap do
    %Capability{
      kind: :session,
      behavior: :example,
      action: :send,
      instance: Ezagent.URI.new!("session://team-alpha/boards/unrelated-#{u()}"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }
  end

  defp sign_cap(target_uri, grantee, behavior, action, workspace) do
    {:ok, authority} = Ezagent.Cap.Authority.open(target_uri, :session)

    cap = %Capability{
      kind: :session,
      behavior: behavior,
      action: action,
      instance: target_uri,
      workspace_uri: workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }

    authority_signed_cap_as!(authority, @issuer, grantee, cap)
  end

  # Grant `grantee` a cap toward `target` by writing its FULL new cap set through
  # the authoritative Store (keeping its existing self-license so it stays active).
  defp grant_via_store!(target_uri, grantee, behavior, action) do
    persist_with!(grantee, [sign_cap(target_uri, grantee, behavior, action, @workspace)])
  end

  # Write the grantee's FULL cap set through the authoritative store — a valid
  # self-license (so the row lands `active`, exercising the ④ lifecycle path) plus
  # the granted caps. This is the write the codex ⓪ hook derives the index from.
  defp persist_with!(grantee, extra_caps) do
    :ok = Store.persist(grantee, [self_license_cap!(grantee, :agent) | extra_caps])
  end
end
