defmodule Ezagent.Behavior.Chat do
  @moduledoc """
  Chat Behavior — Decision P2-D2 K-path: 4 actions, registered per-Kind
  subset to realize Decision #61 "ESR is router not req/resp app".

  ## Action / Kind matrix

      | action    | registered on Kind(s)                  | mode  |
      |-----------|----------------------------------------|-------|
      | :send     | Ezagent.Entity.Session                     | cast  |
      | :join     | Ezagent.Entity.Session                     | call  |
      | :leave    | Ezagent.Entity.Session                     | cast  |
      | :receive  | Ezagent.Entity.User, Ezagent.Entity.Agent      | cast  |

  Session-side actions (`:send / :join / :leave`) mutate the Session's
  `:chat` slice (`members` map / `monitors` ref→URI / `last_seen` URI→DateTime).
  When `:send` is invoked, recipients are derived from `msg.mentions` (or
  all `members` if mentions is empty), excluding the sender, and each
  receives a `chat/receive` dispatch on its own Kind. The Session also
  broadcasts to `esr:session:<self_uri>:events` so the LV chat stream
  picks up the message.

  ## Receive branching

  `:receive` switches on `ctx.kind_module`:
  - `Ezagent.Entity.User` — broadcast to `esr:user:<self_uri>:events`. LV
    subscribes for admin inbox / mention notifications.
  - `Ezagent.Entity.Agent` — wires bridge push via
    `EzagentPluginCc.BridgeRegistry.lookup(agent_uri)` →
    `send(channel_pid, {:to_claude, payload})`. If no v2 bridge is
    bound, the call is a silent no-op (telemetry-only).

  ## Offline state machine (P2-D3 failure modes)

  When a member joins, Session `Process.monitor`s the member's Kind pid.
  On `:DOWN`, `handle_kind_message/3` flips that member's `online` flag
  to false and records `last_seen = now` (no member removal). On rejoin
  (`:join` for an already-known member), the Session uses
  `Ezagent.MessageStore.in_session_since/2(self_uri, last_seen)` to replay
  missed messages — bounded by the @replay_cap in MessageStore (1000)
  per DECISIONS failure mode (4).

  ## Why ctx.self_uri and ctx.kind_module

  Both injected by `Ezagent.Kind.Runtime` immediately before invoke (single
  point of contact, plugins never plumb manually). Session uses
  `ctx.self_uri` to scope MessageStore writes and PubSub topics;
  receivers branch on `ctx.kind_module` to pick the delivery shape
  (broadcast vs bridge push).
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}

  @impl Ezagent.Behavior
  def actions, do: [:send, :receive, :join, :leave, :set_working_copy]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:send, "send a chat message to session members"},
      {:receive, "receive a chat message routed to this Kind (User/Agent inbox)"},
      {:join, "join a session as a member (replays missed messages on rejoin)"},
      {:leave, "leave a session (records last_seen for future rejoin replay)"},
      {:set_working_copy,
       "stage SessionTemplate working-copy edits on the Session before instantiate"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :chat

  @impl Ezagent.Behavior
  def init_slice(_args) do
    # Slice shape is the union across Kinds — Session uses all three
    # maps; User/Agent's :receive doesn't read or write the slice but
    # leaving the keys here means a `Map.get` on any Kind returns the
    # consistent shape (defensive over the BehaviorRegistry per-Kind
    # subset model where User/Agent don't list Chat in `behaviors/0`
    # and so don't init this slice anyway — `Kind.Runtime` defaults
    # missing slices to `%{}`, which the Session-only fields tolerate).
    %{
      # %{URI => %{online: bool}}
      members: %{},
      # %{ref => URI} — Process.monitor refs
      monitors: %{},
      # %{URI => DateTime} — when last seen offline (only present for offline)
      last_seen: %{},
      # Phase 7 completion PR-2 (SPEC §1.3 / §1.6) — the durable
      # source-template record for the orchestrator's working copy.
      # `template_working_copy` is template-SHAPED, not live-runtime
      # shaped (codex rev-3 HIGH-3): `agent_slots` carries the
      # `template://agent/<ws>/<name>` AgentTemplate URI each slot was
      # spawned from (the durable `source_agent_template_uri`), NOT a
      # live `entity://agent` instance URI; routing receivers are slot
      # NAMES, not live URIs. Because Session is `{:snapshot,
      # :on_change}` this field persists across restart.
      #
      # A pre-PR-2 Session snapshot has a `:chat` slice WITHOUT this
      # key. `Ezagent.Kind.Snapshot.load_or_init/3` merges at the
      # slice-key level (`Map.merge(fresh, loaded)`), so the loaded
      # `:chat` slice would replace the fresh one entirely — readers
      # MUST therefore treat a missing key as the default via
      # `template_working_copy/1` below rather than dot-access.
      template_working_copy: default_template_working_copy()
    }
  end

  @doc """
  The empty/default `template_working_copy` shape (Phase 7 completion
  SPEC §1.3 / §1.6).

  Used by `init_slice/1` for fresh Sessions and as the safe default
  when reading a pre-PR-2 Session snapshot whose `:chat` slice has no
  `template_working_copy` key.
  """
  @spec default_template_working_copy() :: map()
  def default_template_working_copy do
    %{
      # [{slot_name :: String.t(),
      #   source_agent_template_uri :: URI.t(),
      #   live_worker_uri :: URI.t(),
      #   generation :: non_neg_integer()}]
      #
      # The 4-tuple (CRITICAL + HIGH-6 hardening fix): `slot_name` is
      # the stable template-shaped key; `source_agent_template_uri` is
      # the `template://agent/<ws>/<name>` the slot was spawned from
      # (the durable source); `live_worker_uri` is the CURRENT
      # session-unique live `entity://agent/...` instance URI;
      # `generation` is the swap counter (0 at Generator init,
      # incremented by each `update_agent_template`). Storing the live
      # URI + generation means readers never re-derive a collision-prone
      # URI from `{workspace, flavor, slot_name}`.
      agent_slots: [],
      # [{matcher_ast :: term(), [slot_name :: String.t()]}]
      # receivers are slot NAMES, resolved to URIs only on instantiate.
      routing_rules: [],
      # URI.t() | nil — the orchestrator agent's AgentTemplate
      orchestrator_template_uri: nil,
      # URI.t() | nil — workspace newly-instantiated sessions land in
      default_workspace_uri: nil,
      # String.t() — human description of the team
      description: ""
    }
  end

  @doc """
  Read the durable `template_working_copy` field from a `:chat` slice,
  defaulting to `default_template_working_copy/0` when the key is
  absent (a pre-PR-2 Session snapshot — see `init_slice/1`).
  """
  @spec template_working_copy(map()) :: map()
  def template_working_copy(slice) when is_map(slice) do
    Map.get(slice, :template_working_copy, default_template_working_copy())
  end

  # --- :send -------------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:send, slice, %{message: %Message{} = msg}, ctx) do
    session_uri = ctx.self_uri

    # 1. Persist — write failure means send failure per DECISIONS
    # impl-time §write-failure; let-it-crash on Repo errors rather than
    # silently dropping the message.
    case MessageStore.write(msg, session_uri) do
      {:ok, stored_msg} ->
        # Plan B (2026-05-17): use stored_msg (which has session_uri
        # stamped) for Resolver + downstream dispatch. The original
        # `msg` arg has session_uri=nil at this point, which makes the
        # new `in_session(session_uri)` matcher (introduced for Feishu
        # binding) return false. Without this fix, in_session-scoped
        # routing rules never fire even when the binding is correct.
        msg = stored_msg

        # 2. Broadcast for in-session subscribers (LV chat stream).
        # Phase 3: include session_uri in payload so multi-session LV
        # subscribers can filter by current session.
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          session_events_topic(session_uri),
          {:chat_message, session_uri, msg}
        )

        # Phase 4-completion PR 9: Resolver is the SINGLE source of
        # truth for routing decisions. No hardcoded fan-out here — the
        # in-session-member fan-out is now expressed as a system_default
        # rule with `receivers: ["$session_members"]` that Resolver
        # expands using the passed members list.
        #
        # Phase 7 PR 31 (IMPL-7-1): plumb workspace_uri into Resolver so
        # workspace-scoped routing rules actually filter. Pre-PR-31 this
        # call used 3-arg resolve/3 which forwarded with `opts = []`,
        # making rules with `workspace_uri != nil` never fire — exactly
        # the V4.4 / V3.2 gap. `WorkspaceRegistry.lookup` returns :error
        # for unbound (legacy) sessions; we pass `workspace_uri: nil`
        # in that case, preserving pre-PR-31 global semantics.
        in_session_members = Map.keys(slice.members)

        workspace_uri =
          case Ezagent.WorkspaceRegistry.lookup(session_uri) do
            {:ok, uri} -> uri
            :error -> nil
          end

        recipients =
          Ezagent.Routing.Resolver.resolve(
            msg,
            session_uri,
            in_session_members,
            workspace_uri: workspace_uri
          )

        for recipient <- recipients do
          if recipient.scheme == "session" do
            dispatch_cross_session(recipient, msg)
          else
            dispatch_receive(recipient, msg, session_uri)
          end
        end

        # PR #144 (SPEC v2 §5.8) — opportunistic external-mirror hook.
        # If a plugin has registered a Behavior on Session Kind for
        # `:notify_external`, dispatch it now so plugin-owned external
        # channels (Feishu mirror, future Slack/Discord/email/webhook)
        # see every chat send. This is the generic side-channel
        # extension point; the Behavior itself decides whether the
        # current session has a binding it cares about. Chat stays
        # plugin-agnostic — no `feishu_*` references here.
        maybe_notify_external(Map.get(ctx, :kind_module), session_uri, msg)

        {:ok, slice, %{stored: true}}

      {:error, reason} ->
        {:error, {:message_store_write_failed, reason}}
    end
  end

  # --- :receive ----------------------------------------------------------

  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    case ctx.kind_module do
      Ezagent.Entity.User ->
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          user_events_topic(ctx.self_uri),
          {:message_received, msg}
        )

        {:ok, slice}

      Ezagent.Entity.Agent ->
        # Phase 7 PR 32c: v1 prototype deleted; v2 CC channel
        # (Phoenix.Channel WS) is the only bridge transport. If
        # no channel is bound for the Agent, the dispatch is a
        # silent no-op below.
        source_session =
          case Map.get(ctx, :caller) do
            %URI{} = u -> URI.to_string(u)
            s when is_binary(s) -> s
            _ -> ""
          end

        # Phase 6 PR 14: pass attachments through to claude so it sees
        # what the operator sent, even when the bridge can't render
        # binary content. Format as a text breadcrumb attached after
        # the body text. PR 26 (Allen 2026-05-18): per channels-reference
        # spec `meta: Record<string, string>`, every meta VALUE must be
        # a string — a list value (the old `attachments` key) caused
        # claude TUI to silently drop the entire notification. Keep
        # attachment info in `content` only; structured form is not
        # representable in the channel meta schema.
        attachments = body_attachments(msg.body)
        attachment_hint = attachment_hint_text(attachments)

        text_with_hint =
          case {body_text(msg.body), attachment_hint} do
            {"", ""} -> ""
            {t, ""} -> t
            {"", hint} -> hint
            {t, hint} -> t <> "\n" <> hint
          end

        base_meta = %{
          "sender" => URI.to_string(msg.sender),
          "message_id" => msg.id,
          "session" => source_session
        }

        meta =
          case first_attachment_path(attachments) do
            nil -> base_meta
            path -> Map.put(base_meta, "file_path", path)
          end

        payload = %{"content" => text_with_hint, "meta" => meta}

        case EzagentPluginCc.BridgeRegistry.lookup(ctx.self_uri) do
          {:ok, channel_pid} ->
            send(channel_pid, {:to_claude, payload})

          :error ->
            # No bound bridge. The agent's PtyServer might be alive but
            # the claude TUI hasn't opened its Phoenix.Channel WS back
            # to ezagent (via `--dangerously-load-development-channels
            # server:esr-bridge`). Until that handshake completes,
            # inbound chat dispatches have nowhere to go.
            #
            # Phase 8c follow-up (Allen 2026-05-20): the prior comment
            # said "Drop silently — telemetry only" but no telemetry
            # was actually emitted, making this the hardest class of
            # "why didn't the agent reply?" bug to debug. Now logs at
            # warning so operators see the drop in /admin/logs +
            # `phx.log`.
            require Logger

            Logger.warning(
              "Chat receive dropped — no BridgeRegistry binding for #{URI.to_string(ctx.self_uri)} " <>
                "(claude TUI hasn't opened its WS channel yet, or the agent has no PtyServer). " <>
                "Message from #{URI.to_string(msg.sender)}: " <>
                String.slice(body_text(msg.body), 0, 80)
            )

            :telemetry.execute(
              [:ezagent, :chat, :receive, :dropped],
              %{count: 1},
              %{recipient: ctx.self_uri, sender: msg.sender, reason: :no_bridge}
            )

            :ok
        end

        {:ok, slice}

      _other ->
        # Should not happen — :receive is only registered for User/Agent.
        {:error, {:receive_unsupported_for_kind, ctx.kind_module}}
    end
  end

  # --- :join -------------------------------------------------------------

  def invoke(:join, slice, %{member: %URI{} = member_uri}, ctx) do
    session_uri = ctx.self_uri

    case KindRegistry.lookup(member_uri) do
      {:ok, member_pid} ->
        ref = Process.monitor(member_pid)

        new_members = Map.put(slice.members, member_uri, %{online: true})
        new_monitors = Map.put(slice.monitors, ref, member_uri)

        # If this member has prior last_seen, replay missed messages.
        replay_messages_since(session_uri, member_uri, slice.last_seen)
        new_last_seen = Map.delete(slice.last_seen, member_uri)

        new_slice = %{
          slice
          | members: new_members,
            monitors: new_monitors,
            last_seen: new_last_seen
        }

        broadcast_membership(session_uri, {:member_joined, member_uri})

        {:ok, new_slice, %{members: Map.keys(new_members)}}

      :error ->
        {:error, {:member_not_registered, member_uri}}
    end
  end

  # --- :leave ------------------------------------------------------------

  def invoke(:leave, slice, %{member: %URI{} = member_uri}, ctx) do
    {ref_to_remove, new_monitors} = pop_monitor_ref(slice.monitors, member_uri)

    if ref_to_remove, do: Process.demonitor(ref_to_remove, [:flush])

    new_slice = %{
      slice
      | members: Map.delete(slice.members, member_uri),
        monitors: new_monitors,
        last_seen: Map.delete(slice.last_seen, member_uri)
    }

    broadcast_membership(ctx.self_uri, {:member_left, member_uri})

    {:ok, new_slice}
  end

  # --- :set_working_copy -------------------------------------------------

  # Phase 7 completion PR-4 (SPEC §1.6) — write the durable
  # `template_working_copy` field on the Session's `:chat` slice. The
  # Generator (`Session.spawn_from_template/2`) populates `agent_slots`
  # + `routing_rules` + `orchestrator_template_uri` + `default_workspace_uri`
  # + `description` from the SessionTemplate; PR-5's orchestrator slot
  # tools maintain `agent_slots` mid-session through this same action.
  #
  # ## HIGH-2 hardening — orchestrator-only authorization
  #
  # `set_working_copy` is a normal Chat action, so dispatch CapBAC step
  # 5.5 derives the needed cap as `{kind: :session, behavior: Chat,
  # instance: <session_uri>}` — which a non-admin user holds
  # STRUCTURALLY (`{:session, :any, :any}` in their workspace). Without
  # an extra gate ANY session-cap holder could blindly overwrite the
  # working copy that `update_template` later hashes.
  #
  # So `invoke` requires an EXPLICIT authority beyond generic
  # session-chat: the caller must EITHER
  #
  # - be the session's orchestrator — hold the exact
  #   `{:within_session, self_uri}` delegated cap (cap #1, which the
  #   Generator grants ONLY to the orchestrator), OR
  # - be the system-internal Generator init path —
  #   `ctx[:system_internal] == true`, set ONLY by
  #   `system_set_working_copy/2`, never reachable from a user dispatch.
  #
  # A normal user holding only default session caps is denied here even
  # though step 5.5 passed.
  def invoke(:set_working_copy, slice, %{template_working_copy: wc}, ctx)
      when is_map(wc) do
    if working_copy_write_authorized?(ctx) do
      new_slice = Map.put(slice, :template_working_copy, wc)
      {:ok, new_slice, %{template_working_copy: wc}}
    else
      {:error, :unauthorized}
    end
  end

  # The HIGH-2 orchestrator-only gate. `ctx.self_uri` is the Session
  # Kind's own URI (injected by `Kind.Runtime` step 5).
  defp working_copy_write_authorized?(ctx) do
    Map.get(ctx, :system_internal) == true or
      orchestrator_cap_present?(ctx)
  end

  # True iff `ctx.caps` carries a `{:within_session, self_uri}` cap on
  # the `:session` kind — i.e. the caller IS this session's orchestrator
  # (cap #1, granted only by the Generator to the orchestrator agent).
  defp orchestrator_cap_present?(ctx) do
    self_uri = Map.get(ctx, :self_uri)
    caps = Map.get(ctx, :caps, MapSet.new())

    case self_uri do
      %URI{} = sess_uri ->
        self_str = URI.to_string(sess_uri)

        Enum.any?(caps, fn
          %Ezagent.Capability{kind: :session, instance: {:within_session, %URI{} = s}} ->
            URI.to_string(s) == self_str

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  @doc """
  Generator-only internal path to write the durable
  `template_working_copy` field (HIGH-2 hardening).

  `Ezagent.Entity.Session.spawn_from_template/2` is the privileged
  bootstrap program that does the FIRST `template_working_copy` write,
  before any orchestrator cap exists. It cannot hold the orchestrator's
  `{:within_session, _}` cap (the session is brand-new), so it uses
  this path: a `chat.set_working_copy` dispatch carrying
  `ctx[:system_internal] = true`. That marker is honored ONLY here and
  by `invoke/4`'s `working_copy_write_authorized?/1` — it is NOT
  settable from any user-facing dispatch (the MCP tool path supplies
  `caps`, never `system_internal`).

  Returns the dispatch result.
  """
  @spec system_set_working_copy(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_working_copy(%URI{} = session_uri, working_copy) when is_map(working_copy) do
    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.set_working_copy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{template_working_copy: working_copy},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             system_internal: true,
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{template_working_copy: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # --- Kind-message hook -------------------------------------------------

  @doc """
  `Ezagent.Kind.Server.handle_info/2` forwards all GenServer messages here.
  Phase 2 handles `:DOWN` from `Process.monitor`; everything else is
  `:ignore`-ed (return value tells the server "slice unchanged").

  On `:DOWN` for a known member ref: flip `online` → false, record
  `last_seen = now`. The monitor ref is removed from `monitors` (no
  point holding a dead ref) but the URI stays in `members` so rejoin
  recognizes it.
  """
  def handle_kind_message({:DOWN, ref, :process, _pid, _reason}, slice, ctx) do
    case Map.pop(slice.monitors, ref) do
      {nil, _} ->
        # Not one of our monitors (could be another Behavior's ref or
        # a stale ref after a leave).
        :ignore

      {member_uri, new_monitors} ->
        now = DateTime.utc_now()

        new_members =
          Map.update(slice.members, member_uri, %{online: false}, &Map.put(&1, :online, false))

        new_last_seen = Map.put(slice.last_seen, member_uri, now)

        new_slice = %{
          slice
          | monitors: new_monitors,
            members: new_members,
            last_seen: new_last_seen
        }

        broadcast_membership(ctx.self_uri, {:member_offline, member_uri, now})

        {:ok, new_slice}
    end
  end

  def handle_kind_message(_other_message, _slice, _ctx), do: :ignore

  # --- Interface schema --------------------------------------------------

  @impl Ezagent.Behavior
  def interface do
    %{
      send: %{
        description: "Post a message into the session and fan it out to members",
        args: %{message: message_schema()},
        returns: %{stored: :boolean},
        modes: [:cast]
      },
      receive: %{
        description: "Deliver a session message to this member (User inbox / Agent bridge)",
        args: %{message: message_schema()},
        returns: %{},
        modes: [:cast]
      },
      join: %{
        description: "Add a member to the session and replay any missed messages",
        args: %{member: :uri},
        returns: %{members: {:list, :uri}},
        # Allow both — admin User joins via :cast at boot (non-blocking);
        # admin or programmatic callers may :call to read members back.
        modes: [:call, :cast]
      },
      leave: %{
        description: "Remove a member from the session",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast]
      },
      set_working_copy: %{
        description:
          "Write the durable template_working_copy field on the Session's :chat " <>
            "slice (the orchestrator's source-template record — Phase 7 SPEC §1.6)",
        args: %{template_working_copy: :map},
        returns: %{template_working_copy: :map},
        modes: [:call]
      }
    }
  end

  # --- Topic helpers (public — Ezagent.Kind.Server / LV subscribe via these) -

  @doc "PubSub topic for in-session events (chat stream feed)."
  @spec session_events_topic(URI.t() | String.t()) :: String.t()
  def session_events_topic(%URI{} = uri), do: session_events_topic(URI.to_string(uri))
  def session_events_topic(uri_str) when is_binary(uri_str), do: "esr:session:#{uri_str}:events"

  @doc "PubSub topic for a User's personal receive notifications."
  @spec user_events_topic(URI.t() | String.t()) :: String.t()
  def user_events_topic(%URI{} = uri), do: user_events_topic(URI.to_string(uri))
  def user_events_topic(uri_str) when is_binary(uri_str), do: "esr:user:#{uri_str}:events"

  # --- Internals ---------------------------------------------------------

  defp dispatch_cross_session(target_session_uri, %Message{} = msg) do
    # Recursively dispatch chat/send on the target session — that
    # session handles its own member fan-out + further routing rules.
    target = URI.new!("#{URI.to_string(target_session_uri)}?action=chat.send")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: msg.sender,
        caps: Ezagent.Entity.User.admin_caps(),
        reply: :ignore
      }
    })
  end

  defp dispatch_receive(recipient_uri, %Message{} = msg, session_uri) do
    target = URI.new!("#{URI.to_string(recipient_uri)}?action=chat.receive")

    # Phase 3d: Session's fan-out to recipients runs under admin caps —
    # the Session is acting on behalf of the system-routed message.
    # Phase 4+ will refine to a dedicated "system-internal" cap when
    # multi-user authorization arrives.
    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: session_uri,
          caps: Ezagent.Entity.User.admin_caps(),
          reply: :ignore
        }
      })

    # PR-3 of Read Receipts rollout (SPEC
    # `docs/superpowers/specs/2026-05-23-read-receipts.md` §10) —
    # mark `:delivered` for the recipient when dispatch succeeds.
    # "Delivered" here = the chat.receive dispatch reached the
    # recipient Kind (cap-checked, queued for invoke). Fire-and-forget
    # — mark failure must not block message fan-out.
    if result == :ok do
      _ = Ezagent.Chat.ReadMarker.mark(session_uri, recipient_uri, msg.id, :delivered)
    end

    result
  end

  # PR #144 SPEC v2 §5.8 — opportunistic external-mirror hook.
  #
  # Look up `BehaviorRegistry.lookup(kind_module, :notify_external)`. If
  # a plugin has registered a Behavior for that action on the Session
  # Kind, dispatch `<session_uri>?action=notify_external.notify_external`.
  # If nothing is registered, this is a cheap ETS lookup + no-op.
  #
  # The behavior path segment is `notify_external` (matches the action
  # name) — `Ezagent.URI.behavior_action/1` derives `{behavior_atom,
  # action_atom}` from the path, but `BehaviorRegistry.lookup/2` keys
  # only on `{kind_module, action}`. The behavior name in the URL is
  # informational; the action atom drives resolution.
  #
  # Plugin contract: a plugin wanting to mirror chat sends to an
  # external system registers:
  #
  #     BehaviorRegistry.register(Ezagent.Entity.Session, :notify_external,
  #                              MyPlugin.Behavior.ExternalMirror)
  #
  # The behavior reads `self_uri` from ctx + its own side-table to
  # decide whether to forward. See
  # `EzagentPluginFeishu.Behavior.FeishuOutbound` for the reference
  # implementation.
  defp maybe_notify_external(nil, _session_uri, _msg), do: :ok

  defp maybe_notify_external(kind_module, session_uri, %Message{} = msg) do
    case Ezagent.BehaviorRegistry.lookup(kind_module, :notify_external) do
      {:ok, _behavior_module} ->
        target = URI.new!("#{URI.to_string(session_uri)}?action=notify_external.notify_external")

        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{
            caller: session_uri,
            caps: Ezagent.Entity.User.admin_caps(),
            reply: :ignore
          }
        })

      :error ->
        :ok
    end
  end

  defp replay_messages_since(_session_uri, _member_uri, last_seen) when last_seen == %{}, do: :ok

  defp replay_messages_since(session_uri, member_uri, last_seen) do
    case Map.get(last_seen, member_uri) do
      nil ->
        :ok

      last_seen_at ->
        for msg <- MessageStore.in_session_since(session_uri, last_seen_at) do
          dispatch_receive(member_uri, msg, session_uri)
        end

        :ok
    end
  end

  defp broadcast_membership(session_uri, event) do
    # Per-session fan-out — the LV chat stream subscribes here for
    # its own session's events.
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      session_events_topic(session_uri),
      event
    )

    # Global fan-out — `EzagentDomainChat.PresenceFanout` subscribes
    # to maintain the `user_uri → MapSet(session_uri)` reverse index
    # without coupling back to this module. Wrapper carries the
    # session_uri the inner `event` lacks (events are
    # `{:member_joined | :member_left | :member_offline, member_uri, ...}`).
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      "esr:session_membership:changes",
      {:session_membership_change, session_uri, event}
    )
  end

  defp pop_monitor_ref(monitors, member_uri) do
    Enum.reduce(monitors, {nil, %{}}, fn
      {ref, ^member_uri}, {nil, acc} -> {ref, acc}
      {ref, uri}, {found_ref, acc} -> {found_ref, Map.put(acc, ref, uri)}
    end)
  end

  # Body comes back from MessageStore.load with string keys (Ecto :map
  # column → JSON-decoded via ecto_sqlite3); freshly-constructed bodies
  # in-flight have atom keys. Accept either to be safe across the
  # dispatch boundary.
  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # Phase 6 PR 14 — attachment helpers for bridge payload.
  defp body_attachments(%{attachments: list}) when is_list(list), do: list
  defp body_attachments(%{"attachments" => list}) when is_list(list), do: list
  defp body_attachments(_), do: []

  # Mirror cc-openclaw channel_server convention: at most one `file_path`
  # string in meta per notification; multi-attachment context lives in the
  # text hint already concatenated to `content`.
  defp first_attachment_path([]), do: nil

  defp first_attachment_path([att | _]) do
    case att[:local_path] || att["local_path"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp first_attachment_path(_), do: nil

  defp attachment_hint_text([]), do: ""

  defp attachment_hint_text(list) do
    parts =
      Enum.map(list, fn att ->
        type = att[:type] || att["type"] || "unknown"
        name = att[:name] || att["name"] || "?"
        "[attachment: type=#{type} name=#{name}]"
      end)

    Enum.join(parts, " ")
  end

  defp message_schema do
    %{
      id: :string,
      sender: :uri,
      mentions: {:list, :uri},
      body: :map,
      ref_id: {:option, :string},
      inserted_at: :map
    }
  end
end
