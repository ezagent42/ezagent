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
  alias Ezagent.IdentityCaps
  alias Ezagent.IdentityCaps.Store
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
    assert IdentityCaps.load_persisted(uri) == []
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
    assert IdentityCaps.load_persisted(uri) == []

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
    refute IdentityCaps.load_persisted(uri) == []
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
    assert IdentityCaps.load_persisted(uri) == []
    refute SelfLicense in captured_behaviors(uri)
  end

  test "RETRYABLE (ITEM 4): a Store failure leaves NO licensed snapshot to skip — a re-run converges" do
    uri = session_uri("retryable")

    write_snapshot(
      uri,
      %{kind_base: %{state: %{behaviors: @pre_cutover_behaviors}}, chat: %{messages: []}},
      ever_created: true
    )

    # Force the AUTHORITATIVE Store write to fail. Store-FIRST (ITEM 4) means the
    # snapshot is NOT rewritten with a license, so the session stays un-migrated
    # and a re-run re-attempts it. Pre-fix (snapshot-first) wrote the licensed
    # snapshot BEFORE the store failed, so `already_principal?` then wrongly
    # SKIPPED it on re-run — a failed migration that could never complete.
    store_key = uri |> Ezagent.URI.instance() |> URI.to_string()
    Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [store_key])
    on_exit(fn -> Application.delete_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris) end)

    assert {:error, _} = Migration.migrate_row(fetch(uri), false)

    # DISCRIMINATOR — no licensed-snapshot residue: the session is NOT
    # already_principal (pre-fix `identity_caps/1` would be `[license]` here).
    assert identity_caps(uri) == []
    refute SelfLicense in captured_behaviors(uri)
    refute Store.has_row?(uri)

    # Clear the forced failure and RE-RUN — it now converges to `:migrated`
    # (pre-fix this returned `:already_principal` on the residue, leaving the
    # store row permanently absent).
    Application.delete_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris)

    assert {:ok, :migrated} = Migration.migrate_row(fetch(uri), false)
    assert SelfLicense in captured_behaviors(uri)
    assert [license] = identity_caps(uri)
    assert Capability.action_of(license) == :self_license
    assert Store.status(uri) == :active
    refute IdentityCaps.load_persisted(uri) == []
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
