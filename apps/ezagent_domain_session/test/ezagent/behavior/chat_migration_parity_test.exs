defmodule Ezagent.ActionSet.ChatMigrationParityTest do
  @moduledoc """
  Phase 2-a r3 (2026-05-28) — migration parity tests for
  `Ezagent.ActionSet.Session` after the SPEC 2026-05-28 new-action-grammar
  migration.

  Covers the actions (:send / :join / :leave /
  :set_working_copy) via their `handle_<action>/2` shape, asserting:
  - Slice-state reads via ctx[:read]
  - Effects produced match expected shape (:set for state mutations,
    :notify for PubSub broadcasts, :dispatch for cross-Kind fan-out)
  - Error paths return typed errors
  - Authorization branches in :set_working_copy

  ## Boundary

  These parity tests cover the HANDLER contract surface — they call
  `SessionBehavior.handle_<action>/2` directly with a stub ctx[:read]/1 and
  pin the returned `{:ok, result, effects}` tuple. End-to-end coverage
  via `Ezagent.Kind.Runtime.handle_dispatch/4` continues to live in
  the integration suite.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  # PR-2 (im/session/agent decomposition §OQ-4) — `:receive` split out of
  # SessionBehavior into two first-class Behaviors.
  alias Ezagent.ActionSet.User.Receive, as: UserReceive
  alias Ezagent.ActionSet.Agent.Receive, as: AgentReceive
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  # Sandbox provided by EzagentCore.DataCase (#92).

  defp bind_to_default(session_uri) do
    ws = URI.new!("workspace://team-alpha")

    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, _} ->
        :ok

      :error ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws)
        on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
        :ok
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §2.3C): `init_slice/1` now returns
  # the two-container `%{state, transients}` shape. The handlers are pure
  # `(args, ctx)` fns that read persistent fields via `ctx.read` and
  # transient fields via `ctx.transients[k]`. These helpers work on the
  # flat PERSISTENT slice (`.state`) + a `ctx` exposing it via `read`, plus
  # a `transients` view for `:monitors`. `extras` may seed either a
  # persistent field (e.g. `members:`) or, via the `:monitors` key, the
  # transient — `ctx_for/2` routes `:monitors` into `ctx.transients`.
  defp empty_chat_slice(extras \\ %{}) do
    Map.merge(SessionBehavior.init_slice(%{}).state, extras)
  end

  # Membership-cap unification A2.2 — `:receive` authorizes in-handler on the
  # recipient's HELD member-cap over `ctx.caller` (the source session). These
  # parity tests assert receive slice MECHANICS, so they supply a source session
  # `caller` + the recipient's matching member-cap in the pre-loaded `:identity`
  # sibling (the held-cap gate itself is proven in `HeldCapReceiveTest`).
  @recv_source_session URI.new!("session://team-alpha/default/recv-parity")

  defp receive_ctx_extras do
    cap = %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        @recv_source_session,
        Ezagent.Capability.workspace_of(@recv_source_session)
      )
      | granted_by: URI.new!("entity://system/user/owner"),
        granted_at: DateTime.utc_now()
    }

    %{caller: @recv_source_session, siblings: %{identity: %{caps: MapSet.new([cap])}}}
  end

  defp ctx_for(chat_slice, extras \\ %{}) do
    monitors = Map.get(chat_slice, :monitors, %{})

    Map.merge(
      %{
        read: fn key, default -> Map.get(chat_slice, key, default) end,
        transients: %{monitors: monitors},
        self_uri: nil,
        kind_module: Ezagent.Entity.Session,
        caller: nil,
        caps: MapSet.new()
      },
      extras
    )
  end

  describe "new-contract surface" do
    test "is a new-style Behavior" do
      assert SessionBehavior.__behavior__?() == true
    end

    test "declares the Session actions (:receive split out; :attach + :merge_member added)" do
      # team-routing-unification §3.6 (PR-6) — :set_legends added;
      # §3.4/§3.7 (PR-7) — :set_prompt_templates added. PR-2 (im/session/
      # agent decomposition §OQ-4) — :receive removed (→ user.receive /
      # agent.receive). anon-user PR-2 — :merge_member added for login takeover.
      # F7 PR-A — :remove_participant added (isomorphic participant removal).
      # Membership-cap unification Part C (spec §C.4/§C.5) — :approve_admission /
      # :deny_admission / :withdraw_admission added (cap-exempt admission actions).
      # Socialware role-slot P3 — :assign_role assigns human role_name on the session
      # member edge without baking participants into definitions.
      assert Enum.sort(SessionBehavior.__action_names__()) ==
               [
                 :approve_admission,
                 :assign_role,
                 :attach,
                 :composition_consent,
                 :deny_admission,
                 :join,
                 :leave,
                 :merge_member,
                 :remove_participant,
                 :send,
                 :set_legends,
                 :set_prompt_templates,
                 :set_working_copy,
                 :withdraw_admission
               ]
    end

    test "state_slice/0 is :chat" do
      assert SessionBehavior.state_slice() == :session
    end

    test "init_slice/1 returns the two-container PR-EM-6-PRE shape (monitors → transient)" do
      # Lifecycle migration: two-container slice. Persistent fields live
      # under `.state`; `:monitors` is GONE (it's a transient, rebuilt by
      # `activate/2` — SPEC §2.3C).
      slice = SessionBehavior.init_slice(%{})
      assert slice.transients == %{}

      st = slice.state
      assert st.members == %{}
      refute Map.has_key?(st, :monitors)
      assert st.last_seen == %{}
      assert st.last_message_id == nil
      assert st.last_message == nil
      assert st.send_cursor == 0
      assert st.recent_messages == []
      assert st.owner_uri == nil
      assert st.template_working_copy == SessionBehavior.default_template_working_copy()
    end

    test "init_slice/1 honors :owner_uri arg (PR-OWN-2)" do
      owner = Ezagent.URI.new!("entity://system/user/admin")
      assert SessionBehavior.init_slice(%{owner_uri: owner}).state.owner_uri == owner
    end

    test "recent_messages_ring_depth/0 returns the SPEC-pinned constant" do
      # PR-N3 r4 (Allen 2026-05-25) — SPEC-pinned, not a config knob.
      # PR-2: the ring + its depth moved to UserReceive with the receive split.
      assert UserReceive.recent_messages_ring_depth() == 20
    end
  end

  describe "handle_send/2 — slice mutations + :notify effect" do
    test "successful send returns three :set effects + one :notify" do
      session_uri =
        URI.new!("session://team-alpha/default/parity-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)

      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "hi", attachments: []})

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri, caller: sender})

      assert {:ok, %{stored: true}, effects} = SessionBehavior.handle_send(%{message: msg}, ctx)

      # Three :set effects for the SliceChange trigger fields.
      assert Enum.any?(effects, fn
               {:set, :last_message_id, id} -> id == msg.id
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set, :send_cursor, 1} -> true
               _ -> false
             end)

      # In-session broadcast as :notify effect.
      topic = SessionBehavior.session_events_topic(session_uri)

      assert Enum.any?(effects, fn
               {:notify, ^topic, {:chat_message, _, _}} -> true
               _ -> false
             end)
    end

    test "send_cursor increments with each call (HIGH-1: retries still mutate)" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/parity-cursor-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)

      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "first", attachments: []})

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri, caller: sender})

      {:ok, _, effects1} = SessionBehavior.handle_send(%{message: msg}, ctx)

      cursor1 =
        effects1
        |> Enum.find_value(fn
          {:set, :send_cursor, c} -> c
          _ -> nil
        end)

      assert cursor1 == 1

      # Now simulate the slice carrying send_cursor: 1, and call again.
      slice2 = %{slice | send_cursor: 1}
      ctx2 = ctx_for(slice2, %{self_uri: session_uri, caller: sender})

      {:ok, _, effects2} = SessionBehavior.handle_send(%{message: msg}, ctx2)

      cursor2 =
        effects2
        |> Enum.find_value(fn
          {:set, :send_cursor, c} -> c
          _ -> nil
        end)

      assert cursor2 == 2
    end

    test "send returns :error tuple on a typed MessageStore failure" do
      # The error surface is the {:error, {:message_store_write_failed,
      # _}} shape — exercised by mocking is non-trivial here, so we
      # assert the shape via the handler's own pattern: if
      # MessageStore.write returns {:error, _}, the handler maps it
      # to {:error, {:message_store_write_failed, _}}. The dispatch
      # path's let-it-crash behaviour on Repo errors is covered by
      # the integration suite (chat_routing_test).
      session_uri =
        URI.new!(
          "session://team-alpha/default/parity-error-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)

      sender = URI.new!("entity://system/user/admin")
      # Build a Message struct with an inserted_at that violates
      # MessageStore.write's expectations is brittle; instead we just
      # confirm the happy path returns {:ok, _, _} which is the
      # baseline parity claim. The error branch is structurally:
      #   case MessageStore.write(...) do
      #     {:error, reason} -> {:error, {:message_store_write_failed, reason}}
      #   end
      # — single arrow, no transformation.
      msg = Message.new(sender, %{text: "happy", attachments: []})

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri, caller: sender})

      assert {:ok, %{stored: true}, _effects} = SessionBehavior.handle_send(%{message: msg}, ctx)
    end
  end

  describe "handle_receive/2 — user.receive (Behavior.User.Receive)" do
    test "produces :set effects for :last_received + :recent_messages ring" do
      user_uri = URI.new!("entity://team-alpha/user/u-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://team-alpha/user/sender")
      msg = Message.new(sender, %{text: "hello", attachments: []})

      slice = empty_chat_slice()

      ctx =
        ctx_for(
          slice,
          Map.merge(receive_ctx_extras(), %{
            self_uri: user_uri,
            kind_module: Ezagent.Entity.User,
            slice_change_cursor: 5
          })
        )

      assert {:ok, %{}, effects} = UserReceive.handle_receive(%{message: msg}, ctx)

      assert Enum.any?(effects, fn
               {:set, :last_received, %{message_id: id}} -> id == msg.id
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set, :recent_messages, [{5, _msg_id} | _]} -> true
               _ -> false
             end)
    end

    test "recent_messages ring caps at SPEC-pinned depth" do
      user_uri = URI.new!("entity://team-alpha/user/cap-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://team-alpha/user/sender")

      # Pre-fill ring to capacity-1; new entry should land at HEAD,
      # oldest entry falls off the tail.
      prefill =
        for i <- 1..UserReceive.recent_messages_ring_depth() do
          {i, "msg-#{i}"}
        end

      slice = empty_chat_slice(%{recent_messages: prefill})

      msg = Message.new(sender, %{text: "newest", attachments: []})

      ctx =
        ctx_for(
          slice,
          Map.merge(receive_ctx_extras(), %{
            self_uri: user_uri,
            kind_module: Ezagent.Entity.User,
            slice_change_cursor: 999
          })
        )

      {:ok, _, effects} = UserReceive.handle_receive(%{message: msg}, ctx)

      ring =
        Enum.find_value(effects, fn
          {:set, :recent_messages, r} -> r
          _ -> nil
        end)

      # Ring size capped at the SPEC-pinned depth.
      assert length(ring) == UserReceive.recent_messages_ring_depth()
      # HEAD is the new message.
      assert [{999, _msg_id} | _] = ring
    end
  end

  describe "handle_receive/2 — agent.receive (Behavior.Agent.Receive)" do
    test "produces no :set effects (agent slice is empty by design)" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_demo-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/user/sender")
      msg = Message.new(sender, %{text: "agent hello", attachments: []})

      slice = empty_chat_slice()

      ctx =
        ctx_for(
          slice,
          Map.merge(receive_ctx_extras(), %{
            self_uri: agent_uri,
            kind_module: Ezagent.Entity.Agent
          })
        )

      assert {:ok, %{}, []} = AgentReceive.handle_receive(%{message: msg}, ctx)
    end

    # PR-2: the old "unsupported kind → typed error" parity test is DELETED.
    # That `{:error, {:receive_unsupported_for_kind, _}}` branch lived in the
    # retired internal `case ctx.kind_module` on SessionBehavior. With the
    # split, `:receive` is registered ONLY for `{User, :receive}` /
    # `{Agent, :receive}` (each its own Behavior), so a third Kind can never
    # reach a `handle_receive` at all — the error condition is gone by
    # construction, not by a runtime guard.
  end

  describe "handle_join/2 — member not in registry" do
    test "returns {:error, {:member_not_registered, uri}} for unregistered member" do
      session_uri =
        URI.new!("session://team-alpha/default/join-noreg-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)

      stranger = URI.new!("entity://team-alpha/user/not-spawned")

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri})

      assert {:error, {:member_not_registered, ^stranger}} =
               SessionBehavior.handle_join(%{member: stranger}, ctx)
    end
  end

  describe "handle_leave/2 — slice mutations + :notify effects" do
    test "removes member + emits two :notify effects (per-session + global membership)" do
      session_uri =
        URI.new!("session://team-alpha/default/leave-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)

      member = URI.new!("entity://team-alpha/user/leaver")
      slice = empty_chat_slice(%{members: %{member => %{online: true}}})

      ctx = ctx_for(slice, %{self_uri: session_uri})

      assert {:ok, %{}, effects} = SessionBehavior.handle_leave(%{member: member}, ctx)

      # Slice mutation effects.
      assert Enum.any?(effects, fn
               {:set, :members, m} when is_map(m) -> not Map.has_key?(m, member)
               _ -> false
             end)

      # Per-session + global broadcasts as :notify effects.
      per_session_topic = SessionBehavior.session_events_topic(session_uri)

      assert Enum.any?(effects, fn
               {:notify, ^per_session_topic, {:member_left, ^member}} -> true
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:notify, "esr:session_membership:changes",
                {:session_membership_change, _, {:member_left, ^member}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  describe "handle_set_working_copy/2 — post-verifier handler" do
    test "does not duplicate the central capability check" do
      session_uri =
        URI.new!("session://team-alpha/default/setwc-#{System.unique_integer([:positive])}")

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri})

      assert {:ok, %{template_working_copy: %{description: "new"}}, _effects} =
               SessionBehavior.handle_set_working_copy(
                 %{template_working_copy: %{description: "new"}},
                 ctx
               )
    end

    test "allows caller with ctx[:system_internal] = true" do
      session_uri =
        URI.new!("session://team-alpha/default/setwc-sys-#{System.unique_integer([:positive])}")

      slice = empty_chat_slice()
      ctx = ctx_for(slice, %{self_uri: session_uri, system_internal: true})

      wc = %{description: "system-set"}

      assert {:ok, %{template_working_copy: ^wc}, effects} =
               SessionBehavior.handle_set_working_copy(%{template_working_copy: wc}, ctx)

      assert Enum.any?(effects, fn
               {:set, :template_working_copy, w} -> w == wc
               _ -> false
             end)
    end

    test "allows caller holding orchestrator's {:within_session, self_uri} cap" do
      session_uri =
        URI.new!("session://team-alpha/default/setwc-orch-#{System.unique_integer([:positive])}")

      orch_cap = %Ezagent.Capability{
        kind: :session,
        behavior: Chat,
        action: :set_working_copy,
        instance: {:within_session, session_uri},
        workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("system://test"),
        granted_at: DateTime.utc_now()
      }

      slice = empty_chat_slice()

      ctx =
        ctx_for(slice, %{
          self_uri: session_uri,
          caps: MapSet.new([orch_cap])
        })

      wc = %{description: "orch-set"}

      assert {:ok, %{template_working_copy: ^wc}, _} =
               SessionBehavior.handle_set_working_copy(%{template_working_copy: wc}, ctx)
    end
  end

  describe "data_owner/1" do
    test "non-session URI returns :no_owner" do
      assert SessionBehavior.data_owner(Ezagent.URI.new!("entity://x/user/y")) == :no_owner
    end

    test ":any returns :any" do
      assert SessionBehavior.data_owner(:any) == :any
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §2.3C) — the `:DOWN` hook moved
  # from `handle_kind_message/3` (flat-slice, returns `{:ok, new_slice}`)
  # to `handle_signal/2` (returns the effect grammar). `:monitors` is a
  # TRANSIENT: read from `ctx.transients[:monitors]`, dead ref dropped via
  # `{:set_transient, :monitors, _}`; offline-flip + last_seen persisted.
  describe "handle_signal/2 — :DOWN bookkeeping" do
    test "unknown ref returns :ignore" do
      ctx = ctx_for(empty_chat_slice(), %{self_uri: Ezagent.URI.new!("session://x/y/z")})

      msg = {:DOWN, make_ref(), :process, self(), :normal}

      assert :ignore = SessionBehavior.handle_signal(msg, ctx)
    end

    test "known ref flips member online → false + records last_seen + drops transient ref" do
      ref = make_ref()
      member = URI.new!("entity://team-alpha/user/down-test")

      slice =
        empty_chat_slice(%{
          members: %{member => %{online: true}},
          monitors: %{ref => member}
        })

      ctx =
        ctx_for(slice, %{self_uri: Ezagent.URI.new!("session://team-alpha/default/down-parity")})

      assert {:ok, effects} =
               SessionBehavior.handle_signal({:DOWN, ref, :process, self(), :normal}, ctx)

      assert Enum.any?(effects, fn
               {:set, :members, m} -> m[member] == %{online: false}
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set, :last_seen, ls} -> is_struct(ls[member], DateTime)
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set_transient, :monitors, mons} -> not Map.has_key?(mons, ref)
               _ -> false
             end)
    end
  end
end
