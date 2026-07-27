defmodule EzagentDomainInstanceMessage.Integration.ChatReceiveUserSliceChangeTest do
  @moduledoc """
  PR-N3 (SPEC v2 `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`
  §3 lines 204-211 + §2.4, Allen 2026-05-25) — producer-pattern proof.

  Drives the production path end-to-end:

      Chat.invoke(:send) → Resolver fan-out → chat.receive on User Kind →
      Chat.invoke(:receive) User-branch mutates :chat slice →
      Kind.Runtime detects new_slice != old_slice →
      Kind.Server.commit_and_notify post-commit emits via
      Ezagent.SliceChange.emit/1 → PubSub broadcast on
      esr:entity:<user_uri>:slice_changed → subscriber receives
      `{:slice_changed, event_map}`.

  ## Invariant proven

  1. **The new topic carries the producer's event** (`{:slice_changed, _}`
     received on `Notifications.subscribe_slice_change(user)`).
  2. **The legacy paths emit NOTHING for this code path** —
     `{:message_received, _}` on `esr:user:<uri>:events` is gone
     (raw broadcast deleted in PR-N3), `{:notification, _, _}` on the
     `Notifications` topic is gone (the `Notifications.notify/3` call
     site was deleted). `refute_received` after `assert_received`
     locks both deletions in.

  ## Out of scope

  - Other producer sites (`Workspace.add_member`, `Identity.grant_cap`)
    still emit legacy `{:notification, _, _}` on their own topics —
    PR-N4 sweeps them. This test only proves the Chat User-branch
    migration.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, RoutingRegistry}
  alias Ezagent.Routing.Resolver
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  setup do
    # Mirror the routing-table fixture pattern from
    # `mention_gated_routing_test.exs`. The migrated `system_default`
    # rule shape `{:always} → [$session_users, $mentions]` fan-outs
    # `chat.receive` to all session members — which is what we need
    # for the User-branch invariant.
    original = Application.get_env(:ezagent_core, :routing_tables)

    on_exit(fn ->
      if original do
        Application.put_env(:ezagent_core, :routing_tables, original)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    :ok
  end

  defp u(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp install_default_rule_table do
    table = String.to_atom("n3_routing_#{u("t")}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    :ok =
      RoutingRegistry.put(
        table,
        Ezagent.Routing.Matcher.always(),
        [Resolver.session_users_token(), Resolver.mentions_token()]
      )

    Application.put_env(:ezagent_core, :routing_tables, [table])
    table
  end

  defp spawn_session do
    session = URI.new!("session://system/default/#{u("n3-sess")}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, URI.new!("workspace://system"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session) end)
    session
  end

  defp join(session, member) do
    target = URI.new!("#{URI.to_string(session)}?action=session.join")

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          authenticated_principal: member,
          caps: MapSet.new([signed_action_cap!(target, member)]),
          reply: :ignore
        }
      })

    await_member(session, member)
  end

  defp await_member(session, member, attempts \\ 100)
  defp await_member(_session, _member, 0), do: flunk("member projection did not converge")

  defp await_member(session, member, attempts) do
    if member in Ezagent.Entity.Session.session_member_uris(session) do
      :ok
    else
      Process.sleep(10)
      await_member(session, member, attempts - 1)
    end
  end

  defp spawn_user(uri) do
    {:ok, _} = Ezagent.Users.create(uri, "pw-not-secret", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
  end

  defp dispatch_send(session, sender, text) do
    msg = Message.new(sender, %{text: text, attachments: []})
    target = URI.new!("#{URI.to_string(session)}?action=session.send")

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          authenticated_principal: sender,
          caps: MapSet.new([signed_action_cap!(target, sender)]),
          reply: :ignore
        }
      })

    msg
  end

  describe "Chat :receive User-branch — slice-change auto-hook end-to-end" do
    test "subscriber receives {:slice_changed, _} on the user's new topic" do
      install_default_rule_table()
      session = spawn_session()

      sender = URI.new!("entity://system/user/#{u("sender")}")
      receiver = URI.new!("entity://system/user/#{u("receiver")}")

      spawn_user(sender)
      spawn_user(receiver)

      join(session, sender)
      join(session, receiver)

      # Subscribe BEFORE dispatch so we don't race the auto-hook
      # broadcast. `subscribe_slice_change/1` is the PR-N2 helper —
      # same call AdminLive.mount/3 makes for the active operator.
      :ok = Ezagent.Notifications.subscribe_slice_change(receiver)

      msg = dispatch_send(session, sender, "n3 proof: producer pattern")

      assert_receive {:slice_changed, event}, 1_000

      # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25): the broadcast
      # envelope is security-minimal — `uri / slice_key / cursor /
      # event_at / result_summary` only. Subscribers needing slice
      # content re-fetch via `Ezagent.Kind.get_slice/2`. The previous
      # `event.new_slice.last_received.message_id` assertion violated
      # the new contract (and the cap-bypass attack surface that
      # contract closes — see
      # `apps/ezagent_core/test/invariants/slice_change_event_carries_no_slice_content_test.exs`).
      assert event.uri == receiver
      assert event.slice_key == :session
      assert is_integer(event.cursor) and event.cursor >= 1
      assert %DateTime{} = event.event_at
      assert event.result_summary == :ok

      # The slice fact still holds — re-fetched via the cap-respecting
      # `Kind.get_slice/2` path (this test runs in-VM so the read
      # succeeds; production code would dispatch a cap-gated read
      # action like `chat.list_recent` instead).
      {:ok, slice} = Ezagent.Kind.read(receiver, :session, spawn: :never)
      assert slice.last_received.message_id == msg.id
      assert %DateTime{} = slice.last_received.at
    end

    test "legacy paths are silent for the migrated User-branch" do
      install_default_rule_table()
      session = spawn_session()

      sender = URI.new!("entity://system/user/#{u("sender")}")
      receiver = URI.new!("entity://system/user/#{u("receiver")}")

      spawn_user(sender)
      spawn_user(receiver)

      join(session, sender)
      join(session, receiver)

      # Subscribe to BOTH legacy topics that the pre-PR-N3 Chat
      # User-branch wrote to. Post-PR-N3 they MUST stay silent for
      # `chat.receive` on User Kind:
      #   • `esr:user:<uri>:events` — the raw `Phoenix.PubSub.broadcast`
      #     deleted from chat.ex:261-265
      #   • `esr:user:<uri>:events` (same topic, different envelope) —
      #     the `Notifications.notify/3` call site deleted from
      #     chat.ex:268-277
      legacy_topic = Ezagent.Notifications.topic(receiver)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, legacy_topic)

      # Subscribe to the new topic too so we have a positive signal to
      # synchronize on — without it, `refute_receive 200` would just
      # be a race with whatever timing the test happens to hit.
      :ok = Ezagent.Notifications.subscribe_slice_change(receiver)

      _msg = dispatch_send(session, sender, "n3 proof: legacy silence")

      # First confirm the new path actually fired (sync barrier).
      assert_receive {:slice_changed, _event}, 1_000

      # NOW assert the legacy envelopes are absent for THIS path.
      # `refute_received` doesn't block; everything dispatched
      # synchronously by Chat.invoke(:receive) has already landed
      # by the time the slice-change event arrives post-commit.
      refute_received {:message_received, _}
      refute_received {:notification, _, _}
    end
  end
end
