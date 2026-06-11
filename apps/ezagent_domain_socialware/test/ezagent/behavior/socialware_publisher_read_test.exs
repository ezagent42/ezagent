defmodule Ezagent.Behavior.SocialwarePublisherReadTest do
  @moduledoc """
  P3-3 authz-boundary GATE for `Ezagent.Behavior.SocialwarePublisherRead`.

  The read actions (`:snapshot` / `:history`) are **cap-exempt** at the
  CapBAC layer, so the handler is the SOLE fail-closed authority. These
  tests drive the pure `(args, ctx)` handlers directly with a synthetic
  `ctx.siblings[:chat]` slice (the exact shape the runtime injects via
  `reads_siblings [:chat]`) to exercise EVERY branch of the security
  predicate:

  Authorize ONLY when ALL hold (else `{:error, :unauthorized}`):
    - `ctx.caller` is a `%URI{}` (reject nil / `:any` / `:system` / non-URI);
    - the `:chat` sibling slice is present + readable;
    - EITHER `owner_uri` is a `%URI{}` AND `== ctx.caller`,
      OR `ctx.caller` is in the `:chat` slice's `members` map (keyed by URI).
  A nil/missing `owner_uri` matches NOTHING; a nil/malformed caller is
  rejected up front.

  Cases covered (the brief's (a)-(g)):
    (a) chat `kind: :session` cap holder who is NOT a socialware member → denied
        (the cap-exempt path never even consults caps; a non-member caller
        with the WRONG identity is denied by the live check);
    (b) owner CAN — including the owner of a pre-existing (P0-P2) session;
    (c) a current non-owner member CAN;
    (d) a non-member is denied;
    (e) an ex-member (post-LEAVE) is denied via the LIVE re-check;
    (f) a nil/:any/:system caller against an OWNERLESS session is denied;
    (g) a malformed caller is denied.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.SocialwarePublisherRead, as: SPR
  alias Ezagent.Publisher.Event

  @owner Ezagent.URI.entity(:team_alpha, :user, "owner-spr")
  @member Ezagent.URI.entity(:team_alpha, :agent, "member-spr")
  @stranger Ezagent.URI.entity(:team_alpha, :user, "stranger-spr")
  @self_uri Ezagent.URI.session(:team_alpha, :socialware, "spr-1")

  # A non-empty publisher ring so `snapshot`/`history` return real data
  # when authorized (proving the reads work, not just that authz passes).
  defp ring do
    now = DateTime.utc_now()

    [
      %Event{
        cursor: 1,
        publisher_uri: @self_uri,
        slice_key: :surface,
        event_at: now,
        payload: %{a: 1}
      },
      %Event{
        cursor: 2,
        publisher_uri: @self_uri,
        slice_key: :turns,
        event_at: now,
        payload: %{b: 2}
      }
    ]
  end

  # Build a ctx as the runtime would: the publisher trunk fields readable
  # via `ctx.read`, and the `:chat` sibling slice present (normalized flat).
  defp ctx(caller, chat_slice) do
    state = %{ring: ring(), cursor: 2, retention: 100}

    %{
      self_uri: @self_uri,
      caller: caller,
      reply: :none,
      read: fn key, default -> Map.get(state, key, default) end,
      transients: %{},
      siblings: %{chat: chat_slice},
      caps: MapSet.new()
    }
  end

  defp owned_chat(owner, members \\ %{}) do
    %{owner_uri: owner, members: members, last_seen: %{}}
  end

  describe "action set + cap exemption (the security shape)" do
    test "action set is EXACTLY [:snapshot, :history] — no subscribe_from" do
      assert Enum.sort(SPR.actions()) == [:history, :snapshot]
      refute :subscribe_from in SPR.actions()
    end

    test "both read actions are cap-exempt" do
      assert Enum.sort(SPR.cap_exempt_actions()) == [:history, :snapshot]
    end

    test "declares reads_siblings [:chat]" do
      assert SPR.reads_siblings() == [:chat]
    end

    test "declares state_slice :publisher (reads the owner's slice)" do
      assert SPR.state_slice() == :publisher
    end
  end

  describe "(b) owner CAN read — incl. owner of a pre-existing session (no cap, no backfill)" do
    test "snapshot: owner_uri == caller authorizes" do
      chat = owned_chat(@owner)
      assert {:ok, %{cursor: 2, state: %{b: 2}}, []} = SPR.handle_snapshot(%{}, ctx(@owner, chat))
    end

    test "history: owner_uri == caller authorizes and returns the window" do
      chat = owned_chat(@owner)

      assert {:ok, %{events: events}, []} =
               SPR.handle_history(%{from: :earliest, to: :latest}, ctx(@owner, chat))

      assert length(events) == 2
    end
  end

  describe "(c) a current non-owner member CAN read" do
    test "snapshot: caller ∈ members authorizes even when owner differs" do
      chat = owned_chat(@owner, %{@member => %{online: true}})
      assert {:ok, %{cursor: 2}, []} = SPR.handle_snapshot(%{}, ctx(@member, chat))
    end

    test "history: caller ∈ members authorizes" do
      chat = owned_chat(@owner, %{@member => %{online: false}})

      assert {:ok, %{events: _}, []} =
               SPR.handle_history(%{from: :earliest, to: :latest}, ctx(@member, chat))
    end
  end

  describe "(a)/(d) a non-member (incl. a chat kind:session cap holder) is denied" do
    test "snapshot: stranger who is neither owner nor member → unauthorized" do
      chat = owned_chat(@owner, %{@member => %{online: true}})
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(@stranger, chat))
    end

    test "history: stranger → unauthorized" do
      chat = owned_chat(@owner, %{@member => %{online: true}})

      assert {:error, :unauthorized} =
               SPR.handle_history(%{from: :earliest, to: :latest}, ctx(@stranger, chat))
    end
  end

  describe "(e) an ex-member (after LEAVE) is denied via the LIVE re-check" do
    test "member present → authorized; same caller after LEAVE (removed from members) → denied" do
      # While a member:
      joined = owned_chat(@owner, %{@member => %{online: true}})
      assert {:ok, %{cursor: 2}, []} = SPR.handle_snapshot(%{}, ctx(@member, joined))

      # After LEAVE the membership map no longer contains the URI. No revoke
      # step — the LIVE read denies immediately.
      left = owned_chat(@owner, %{})
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(@member, left))
    end
  end

  describe "(f) nil/:any/:system caller against an OWNERLESS session is denied (the cap-exempt + nil-owner trap)" do
    test "nil caller, nil owner, empty members → unauthorized" do
      chat = owned_chat(nil, %{})
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(nil, chat))
    end

    test ":any caller, nil owner → unauthorized" do
      chat = owned_chat(nil, %{})
      assert {:error, :unauthorized} = SPR.handle_history(%{}, ctx(:any, chat))
    end

    test ":system caller, nil owner → unauthorized" do
      chat = owned_chat(nil, %{})
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(:system, chat))
    end

    test "a nil/:any caller MUST NOT match a nil owner_uri (no allow-if-owner-nil branch)" do
      # Even if the caller were somehow nil and owner were nil, equality must
      # NOT authorize — the predicate rejects a non-URI caller up front AND a
      # nil owner matches nothing.
      chat = owned_chat(nil, %{})
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(nil, chat))
    end
  end

  describe "(g) a malformed caller is denied" do
    test "binary caller → unauthorized" do
      chat = owned_chat(@owner)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx("entity://x", chat))
    end

    test "map caller → unauthorized" do
      chat = owned_chat(@owner)
      assert {:error, :unauthorized} = SPR.handle_history(%{}, ctx(%{not: "a uri"}, chat))
    end

    test "malformed (non-canonical, :authority-set) %URI{} caller → unauthorized even if it equals owner_uri (codex P3-3 HIGH)" do
      # A %URI{} built the deprecated way (URI.parse sets :authority) is NON-canonical.
      # Even if it is structurally placed as BOTH caller and owner_uri, the
      # valid_caller_uri? guard rejects it before the owner equality check.
      malformed = URI.parse("entity://team-alpha/user/owner-spr")
      assert malformed.authority != nil, "fixture must be a non-canonical URI"

      chat = owned_chat(malformed)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(malformed, chat))
    end

    test "non-entity %URI{} caller (session scheme) → unauthorized even if it equals owner_uri" do
      not_a_principal = @self_uri
      chat = owned_chat(not_a_principal)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(not_a_principal, chat))
    end

    test "entity %URI{} caller with a non-principal path → unauthorized" do
      bad_shape = %URI{scheme: "entity", host: "team-alpha", path: "/notatype/x"}
      chat = owned_chat(bad_shape)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(bad_shape, chat))
    end

    test "entity %URI{} caller with a SUBRESOURCE path → unauthorized even if it equals owner_uri (codex P3-3 r2 HIGH)" do
      # A canonical entity URI but with extra path segments — NOT a bare
      # principal instance. Placed as both caller and owner_uri; still denied.
      subresource = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice/auth/login"}
      chat = owned_chat(subresource)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(subresource, chat))
    end

    test "entity %URI{} caller carrying a QUERY → unauthorized even if it equals owner_uri (codex P3-3 r2 HIGH)" do
      with_query = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice", query: "action=x"}
      chat = owned_chat(with_query)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(with_query, chat))
    end

    test "entity %URI{} caller carrying a FRAGMENT → unauthorized even if it equals owner_uri" do
      with_frag = %URI{scheme: "entity", host: "team-alpha", path: "/user/alice", fragment: "x"}
      chat = owned_chat(with_frag)
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(with_frag, chat))
    end
  end

  describe "missing/unreadable :chat sibling slice → fail closed" do
    test "owner caller but :chat sibling absent → unauthorized" do
      state = %{ring: ring(), cursor: 2, retention: 100}

      ctx = %{
        self_uri: @self_uri,
        caller: @owner,
        reply: :none,
        read: fn key, default -> Map.get(state, key, default) end,
        transients: %{},
        siblings: %{},
        caps: MapSet.new()
      }

      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx)
    end

    test ":chat sibling present but not a map → unauthorized" do
      assert {:error, :unauthorized} = SPR.handle_snapshot(%{}, ctx(@owner, :not_a_map))
    end
  end
end
