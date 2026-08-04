defmodule Ezagent.Socialware.ExternalFeedAnonShareTest do
  @moduledoc """
  A5 — the anon-share resource projection in the SHARED external read pipeline.

  `ExternalFeed.snapshot/2` is the one anonymous content pipeline (hello's
  official site rides it too), so the projection is pinned as a UNIFORM
  contract: `resources` is always present — `[]` for every session without an
  ENABLED share binding — and a populated projection is produced by a REAL
  cap-gated dispatch made AS THE ADMITTED VISITOR, exercising the read key it
  was BORN WITH at admission (`AnonUser.anon_share_read_caps/1`).

  The money tests: ⓪ a caller that was never admitted holds no key → nothing
  (per-caller fail-closed); ③ the target's authority rotates → the projection
  vanishes on the next snapshot even though the share row is still ON — the key
  is load-bearing, not decoration.
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ezagent.Socialware.{AnonAdmission, AnonShare, ExternalFeed}

  defmodule SharedTarget do
    @moduledoc false
    # Mirrors the domain_session test target (`CompositionGrantTargetBehavior`)
    # — an owner-resolvable agent behavior with one read action — but lives here
    # because per-app test support is not shared across umbrella apps.
    # lifecycle:state_slice_override
    use Ezagent.Lifecycle, state_slice: :anon_share_proj_target

    action(:get_tree,
      args: %{},
      returns: %{ok: :boolean},
      caps: [:get_tree],
      modes: [:call],
      description: "read action"
    )

    action(:get_summary,
      args: %{},
      returns: %{n: :integer},
      caps: [:get_summary],
      modes: [:call],
      description: "second read action"
    )

    def required_caps do
      %{
        get_tree: Ezagent.Capability.cap(:agent, __MODULE__, :get_tree),
        get_summary: Ezagent.Capability.cap(:agent, __MODULE__, :get_summary)
      }
    end

    def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)

    @impl Ezagent.Lifecycle
    def create(_args), do: {:ok, %{}}

    def handle_get_tree(_args, _ctx), do: {:ok, %{ok: true}, []}

    def handle_get_summary(_args, _ctx), do: {:ok, %{n: 7}, []}
  end

  test "① an admitted anon sees the shared target through its born-with read key" do
    owner = user_uri("proj-owner")
    target = live_target("proj-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    anon = admit!(session_uri)

    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, anon)

    assert [resource] = snapshot.resources
    assert resource["target"] == URI.to_string(target)
    assert resource["action"] == "get_tree"
    assert resource["data"] == %{ok: true}

    # The uniform contract: the ordinary snapshot keys are untouched.
    for key <- [:messages, :page, :shell, :shell_css] do
      assert Map.has_key?(snapshot, key)
    end
  end

  test "⓪ a caller that was NEVER admitted holds no key → resources is empty (fail-closed)" do
    owner = user_uri("cold-owner")
    target = live_target("cold-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    # A drive-by URI that skipped admission: the page itself is readable
    # (web_anon_access), but no admission ⇒ no born-with key ⇒ no projection.
    stranger = Ezagent.URI.new!("entity://system/user/never-admitted-#{u()}")

    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, stranger)
    assert snapshot.resources == []
  end

  test "② disable flips the projection off for an ALREADY-admitted anon; other keys intact" do
    owner = user_uri("off-owner")
    target = live_target("off-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    anon = admit!(session_uri)
    assert {:ok, %{resources: [_]}} = ExternalFeed.snapshot(session_uri, anon)

    assert :ok = AnonShare.disable(target, owner)

    # The anon still HOLDS its born-with key — but the projection is row-gated
    # (`by_anon_session/1` returns ENABLED rows only), so one flip goes dark for
    # every visitor at once: the link_login revocation semantics (codex D3).
    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, anon)
    assert snapshot.resources == []

    for key <- [:messages, :page, :shell, :shell_css] do
      assert Map.has_key?(snapshot, key)
    end
  end

  test "③ a revoked key (authority rotation) empties the projection even while the share row is ON" do
    owner = user_uri("rot-owner")
    target = live_target("rot-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    anon = admit!(session_uri)
    assert {:ok, %{resources: [_]}} = ExternalFeed.snapshot(session_uri, anon)

    # Rotate the TARGET's authority: every key toward it (including this anon's
    # born-with one) is now stale-generation and fails step-5.5 verification.
    assert {:ok, _} = Ezagent.Cap.Authority.regenesis(target, :agent)

    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, anon)

    assert snapshot.resources == [],
           "a dead key must make the resource disappear — the cap is load-bearing, not decoration"
  end

  test "④ a share row at a non-read tier mints NO key — read-only is structural, not a caller convention" do
    owner = user_uri("tier-owner")
    target = live_target("tier-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    # Widen the tier behind `AnonShare.enable/4`'s back — exactly what a future
    # caller (or a hand-written row) could do. The mint site must refuse.
    {1, _} =
      EzagentCore.Repo.update_all(
        from(s in Ezagent.Socialware.ShareSetting,
          where: s.anon_session_uri == ^URI.to_string(session_uri)
        ),
        set: [access: "operate"]
      )

    anon = admit!(session_uri)

    assert {:ok, caps} = Ezagent.EntityCaps.effective_caps(anon)

    refute Enum.any?(caps, &(&1.action == :get_tree)),
           "an operate-tier row must not hand an anonymous visitor any key toward the target"

    assert {:ok, %{resources: []}} = ExternalFeed.snapshot(session_uri, anon)
  end

  test "⑥ the read key is granted BY THE OWNER, not by the system principal" do
    owner = user_uri("granter-owner")
    target = live_target("granter-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    anon = admit!(session_uri)
    assert {:ok, caps} = Ezagent.EntityCaps.effective_caps(anon)

    share_key = Enum.find(caps, &(&1.action == :get_tree))
    assert share_key, "the admitted anon must hold the share read key"

    # #154 — granter ≡ data_owner. The anon's OTHER born-with caps stay
    # rule-driven (canonical admin); only this one carries the owner.
    assert Ezagent.URI.stable_key(share_key.granted_by) == Ezagent.URI.stable_key(owner),
           "the share read key must be granted by the share's owner, got " <>
             inspect(share_key.granted_by)

    refute Ezagent.URI.stable_key(share_key.granted_by) ==
             Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)),
           "the share key must no longer carry the system principal as granter"

    # NOTE — the anon's OTHER caps legitimately carry the owner too, and that is
    # not a leak of this change: the dedicated public session is CREATED BY the
    # share owner, so `session.receive` granted at join is the session owner's
    # grant over the session owner's session. (The `session.join` entitlement is
    # not among them at all — `consume_join_entitlement` spends it at join.)

    # And the key still works end to end.
    assert {:ok, %{resources: [_]}} = ExternalFeed.snapshot(session_uri, anon)
  end

  test "⑤ `Cap.revoke_all_to/2` — the PRODUCTION revocation entry — empties the projection" do
    owner = user_uri("revoke-owner")
    target = live_target("revoke-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree])

    anon = admit!(session_uri)
    assert {:ok, %{resources: [_]}} = ExternalFeed.snapshot(session_uri, anon)

    # ③ rotates the authority directly; this exercises the entry real code calls
    # (deleting the resource, offboarding an owner) — the bump happens inside the
    # target's own mailbox and swaps its live authority, which is a strictly
    # longer path than `regenesis/2`.
    # The owner's grant authority over its own resource, via the production path
    # (`TargetAuthority.ensure/2` — admin-authorized, target-signed).
    :ok = Ezagent.Identity.TargetAuthority.ensure(owner, target)
    {:ok, owner_caps} = Ezagent.EntityCaps.effective_caps(owner)

    assert {:ok, _generation} =
             Ezagent.Cap.revoke_all_to(target, %{
               caller: owner,
               authenticated_principal: owner,
               caps: MapSet.new(owner_caps)
             })

    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, anon)

    assert snapshot.resources == [],
           "the production revocation entry must land on the very next snapshot"

    assert Map.has_key?(snapshot, :messages), "the rest of the anon page still renders"
  end

  test "⑦ every declared action is projected — mint and projection describe the same surface" do
    owner = user_uri("multi-owner")
    target = live_target("multi-board", owner)

    assert {:ok, %{session: session_uri}} =
             AnonShare.enable(target, owner, SharedTarget, [:get_tree, :get_summary])

    anon = admit!(session_uri)

    assert {:ok, snapshot} = ExternalFeed.snapshot(session_uri, anon)

    # Admission minted a key per declared action; the page must render both,
    # otherwise the visitor holds keys nothing ever spends.
    assert MapSet.new(snapshot.resources, & &1["action"]) ==
             MapSet.new(["get_tree", "get_summary"])

    assert Enum.find(snapshot.resources, &(&1["action"] == "get_summary"))["data"] == %{n: 7}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  # The REAL admission path (`AnonIngress` → this) — the anon is born with the
  # join cap + view caps + (A5) the share read key, spawned, and joined.
  defp admit!(session_uri) do
    assert {:ok, %{anon_uri: anon_uri}} =
             AnonAdmission.admit_anonymous_participant(session_uri)

    anon_uri
  end

  defp live_target(name, owner) do
    uri = Ezagent.URI.new!("entity://system/agent/#{name}-#{u()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: [SharedTarget],
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.new!("workspace://system"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp user_uri(name) do
    uri = Ezagent.URI.new!("entity://system/user/#{name}-#{u()}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{u()}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end
end
