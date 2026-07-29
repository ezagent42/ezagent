defmodule Ezagent.Socialware.SessionSelfLicenseMigrationTest do
  @moduledoc """
  #189 PR-3 FIX 4 — the governed Session self-license migration.

  The load-bearing invariant is the NO-RESURRECTION test: a destroyed
  (marker-only) session must NEVER be minted a fresh self-license. The
  pass-after is the pre-cutover round-trip: a genuinely pre-carrier session
  (captured behavior list WITHOUT SelfLicense) becomes a principal.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.{KindBase, SelfLicense}
  alias Ezagent.Cap
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.EntityCaps
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Socialware.SessionSelfLicenseMigration, as: Migration

  # A GENUINELY pre-cutover captured behavior list — built EXPLICITLY without
  # SelfLicense (NOT from today's `Session.behaviors/0`, which would already
  # include the carrier and make the test vacuous — codex's explicit warning).
  @pre_cutover_behaviors [Ezagent.ActionSet.Session]

  test "NO-RESURRECTION: a destroyed (marker-only) session is NOT minted a self-license" do
    uri = session_uri("destroyed")
    # A destroyed session: `SnapshotStore.delete` left the ever_created marker
    # with empty state, and (post-FIX-3) no active store row.
    write_snapshot(uri, %{}, ever_created: true)
    refute Store.has_row?(uri)

    assert {:ok, :destroyed} = Migration.migrate_row(fetch(uri), false)

    # The buried session was NOT resurrected — no store row, no self-license.
    refute Store.has_row?(uri)
    assert EntityCaps.load_persisted(uri) == []
  end

  test "PRE-CUTOVER round-trip: a pre-carrier session becomes a principal" do
    uri = session_uri("pre-cutover")

    # kind_base WITHOUT SelfLicense + NO :identity slice + REAL session state.
    write_snapshot(
      uri,
      %{
        kind_base: %{state: %{behaviors: @pre_cutover_behaviors}},
        chat: %{messages: []}
      },
      ever_created: true
    )

    refute SelfLicense in captured_behaviors(uri)
    refute Store.has_row?(uri)
    assert EntityCaps.load_persisted(uri) == []

    assert {:ok, :migrated} = Migration.migrate_row(fetch(uri), false)

    # 1. `:kind_base` now carries SelfLicense.
    assert SelfLicense in captured_behaviors(uri)

    # 2. the snapshot `:identity` slice carries a current self-license.
    assert [license] = identity_caps(uri)
    assert Capability.action_of(license) == :self_license
    assert Cap.Authority.verify_against_current(license, uri, uri)

    # 3. the durable store row is `active` and the principal reads non-empty on
    #    the store-authoritative persisted plane (what the principal gate reads).
    assert Store.status(uri) == :active
    refute EntityCaps.load_persisted(uri) == []
  end

  test "IDEMPOTENT: re-running on a migrated session mints nothing more" do
    uri = session_uri("idempotent")

    write_snapshot(
      uri,
      %{kind_base: %{state: %{behaviors: @pre_cutover_behaviors}}, chat: %{messages: []}},
      ever_created: true
    )

    assert {:ok, :migrated} = Migration.migrate_row(fetch(uri), false)
    [license] = identity_caps(uri)

    # Second run: already a principal — no change.
    assert {:ok, :already_principal} = Migration.migrate_row(fetch(uri), false)
    assert [^license] = identity_caps(uri)
    assert Store.status(uri) == :active
  end

  test "REVOKED: a regenesis'd session is adopted revoked_unprovisioned, never minted active" do
    uri = session_uri("revoked")

    write_snapshot(
      uri,
      %{kind_base: %{state: %{behaviors: @pre_cutover_behaviors}}, chat: %{messages: []}},
      ever_created: true
    )

    # Open then REVOKE (regenesis) the session's authority → generation_count > 1.
    assert {:ok, _} = Cap.Authority.open(uri, :session)
    assert {:ok, _} = Cap.Authority.regenesis(uri, :session)
    assert Cap.Authority.generation_count(uri) > 1

    assert {:ok, :revoked_adopted} = Migration.migrate_row(fetch(uri), false)

    # Recorded inert, NOT resurrected: revoked_unprovisioned, no self-license,
    # and the snapshot was left un-augmented.
    assert Store.status(uri) == :revoked_unprovisioned
    assert EntityCaps.load_persisted(uri) == []
    refute SelfLicense in captured_behaviors(uri)
  end

  # ---- helpers --------------------------------------------------------------

  defp session_uri(suffix),
    do: Ezagent.URI.new!("session://team-alpha/default/#{suffix}-#{System.unique_integer([:positive])}")

  defp write_snapshot(uri, state, opts) do
    uri_str = URI.to_string(uri)
    ws = uri |> Ezagent.URI.workspace_of() |> URI.to_string()
    binary = :erlang.term_to_binary(Ezagent.Kind.Snapshot.strip_transients(state))
    mark? = Keyword.get(opts, :ever_created, false)

    {:ok, _} =
      KindSnapshot.upsert(uri_str, "session", binary, 0, ws, mark_ever_created: mark?)
  end

  defp fetch(uri), do: KindSnapshot.get(URI.to_string(uri))

  defp captured_behaviors(uri) do
    {:ok, state} = KindSnapshot.decode_state(fetch(uri))
    KindBase.behaviors_in_slice(Map.get(state, KindBase.state_slice())) || []
  end

  defp identity_caps(uri) do
    {:ok, state} = KindSnapshot.decode_state(fetch(uri))

    case Map.get(state, :identity) do
      %{state: %{caps: caps}} -> MapSet.to_list(caps)
      %{caps: caps} -> MapSet.to_list(caps)
      _ -> []
    end
  end
end
