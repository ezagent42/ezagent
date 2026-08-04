defmodule Ezagent.Socialware.AnonShareTest do
  @moduledoc """
  A5 — `link_anon` provisioning (`Ezagent.Socialware.AnonShare`).

  The shape Allen approved on #1594: every anonymously-shared resource gets its
  OWN public session (one shared thing per session ⇒ a visitor can never reach
  someone else's share). The read key is born-with-minted to each ADMITTED anon
  at admission (`AnonUser.anon_share_read_caps/1`) — the session-as-holder
  variant was refuted empirically (sessions mount no Identity storage actions;
  see `AnonShare` moduledoc "Who holds the key").

  These tests pin the properties that make that safe: only the owner may enable,
  a refused enable leaves NOTHING behind, provisioning is idempotent (same target
  ⇒ same session), and disable actually withdraws — not merely hides.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{AnonShare, ShareSetting}
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "owner enables anon sharing → a dedicated public session is provisioned and recorded" do
    owner = user_uri("as-owner")
    target = live_agent("as-board", owner, [Target])

    assert {:ok, %{session: session_uri, setting: setting}} =
             AnonShare.enable(target, owner, Target, [:get_tree])

    # The session is the deterministic per-target one (the URI is derived, not
    # random — that is what makes re-enabling idempotent).
    assert session_uri == AnonShare.session_uri_for(target)
    assert %URI{scheme: "session"} = session_uri

    # The share row records the binding, at the most-open rung, read-only.
    assert setting.visibility == "link_anon"
    assert setting.access == "read"
    assert setting.anon_session_uri == URI.to_string(session_uri)

    # …and the REVERSE lookup — the only question the anon read path asks.
    assert %ShareSetting{} = found = ShareSetting.by_anon_session(session_uri)
    assert found.target_uri == URI.to_string(target)
  end

  test "the dedicated session is anonymously readable (that is what web_anon_access buys)" do
    owner = user_uri("as-pub-owner")
    target = live_agent("as-pub-board", owner, [Target])

    assert {:ok, %{session: session_uri}} = AnonShare.enable(target, owner, Target, [:get_tree])

    assert Ezagent.Socialware.Installation.web_anon_access?(session_uri),
           "the provisioned session must be public — otherwise an anon visitor is bounced to /login"
  end

  test "a NON-owner cannot enable, and the refusal leaves no session and no row" do
    owner = user_uri("as-no-owner")
    attacker = user_uri("as-attacker")
    target = live_agent("as-no-board", owner, [Target])

    assert {:error, {:anon_share_not_target_owner, _, _}} =
             AnonShare.enable(target, attacker, Target, [:get_tree])

    # Fail-closed BOTH ways: no share row, and nothing was provisioned for the
    # attacker to point a link at.
    refute ShareSetting.get(target)
    refute Ezagent.Kind.alive?(AnonShare.session_uri_for(target))
  end

  test "a link_anon row cannot borrow someone else's public session — only its own derived one" do
    owner = user_uri("as-borrow-owner")
    target = live_agent("as-borrow-board", owner, [Target])
    other = live_agent("as-borrow-other", owner, [Target])

    # Provision `other`'s anon page for real, then try to point THIS target's
    # share row at it. Without the derivation check the row would be written,
    # and `other`'s page would start rendering `target`'s data AND minting
    # `target`'s read key to everyone admitted there.
    assert {:ok, %{session: other_session}} = AnonShare.enable(other, owner, Target, [:get_tree])

    assert {:error, :anon_share_session_not_derived} =
             Ezagent.Socialware.Share.enable(target, owner, Target, [:get_tree],
               visibility: :link_anon,
               access: :read,
               anon_session_uri: other_session
             )

    refute ShareSetting.get(target)
    # `other`'s own binding is untouched — it still resolves to `other`.
    assert %ShareSetting{target_uri: bound} = ShareSetting.by_anon_session(other_session)
    assert bound == URI.to_string(Ezagent.URI.instance(other))
  end

  test "re-enabling is idempotent — same session, one row, no duplicate provisioning" do
    owner = user_uri("as-idem-owner")
    target = live_agent("as-idem-board", owner, [Target])

    assert {:ok, %{session: first}} = AnonShare.enable(target, owner, Target, [:get_tree])
    assert {:ok, %{session: second}} = AnonShare.enable(target, owner, Target, [:get_tree])

    assert first == second
    assert %ShareSetting{} = ShareSetting.by_anon_session(first)
  end

  test "disable turns the anon page off — the reverse lookup stops resolving" do
    owner = user_uri("as-off-owner")
    target = live_agent("as-off-board", owner, [Target])

    assert {:ok, %{session: session_uri}} = AnonShare.enable(target, owner, Target, [:get_tree])
    assert %ShareSetting{} = ShareSetting.by_anon_session(session_uri)

    assert :ok = AnonShare.disable(target, owner)

    # `by_anon_session/1` only returns ENABLED rows, so the read path resolves to
    # nothing the moment the owner flips it off — every outstanding link dies at
    # once, which is the whole point of the per-resource toggle.
    refute ShareSetting.by_anon_session(session_uri)
  end

  test "a non-owner cannot disable someone else's anon share" do
    owner = user_uri("as-dis-owner")
    attacker = user_uri("as-dis-attacker")
    target = live_agent("as-dis-board", owner, [Target])

    assert {:ok, %{session: session_uri}} = AnonShare.enable(target, owner, Target, [:get_tree])

    assert {:error, {:share_setting_not_target_owner, _, _}} =
             AnonShare.disable(target, attacker)

    assert %ShareSetting{} = ShareSetting.by_anon_session(session_uri)
  end

  # ── fixtures (same shape as share_test.exs) ──────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp live_agent(name, owner, behaviors) do
    uri = Ezagent.URI.new!("entity://system/agent/#{name}-#{u()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  # The `system` workspace is a REAL provisioned workspace in the test env — session
  # creation goes through `WorkspaceOwnerGate`, so a merely-bound workspace (as in
  # share_test.exs, which never creates sessions) is not enough here.
  defp workspace_uri, do: Ezagent.URI.new!("workspace://system")

  defp user_uri(name) do
    uri = Ezagent.URI.new!("entity://system/user/#{name}-#{u()}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{u()}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end
end
