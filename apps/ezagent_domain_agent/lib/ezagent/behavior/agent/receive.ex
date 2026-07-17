defmodule Ezagent.ActionSet.Agent.Receive do
  @moduledoc """
  `agent.receive` — the Agent Kind's active live-process delivery
  `:receive` Behavior.

  ## Why this exists (im/session/agent decomposition — PR-2)

  The single pre-split session `:receive` handler used to branch
  internally on `ctx[:kind_module]` (`Entity.User` → inbox slice;
  `Entity.Agent` → AgentBridge). SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §OQ-4 / §3.3 splits that one action into TWO first-class Behaviors —
  `user.receive` (`Ezagent.ActionSet.User.Receive`, passive inbox) and
  `agent.receive` (this module, active live-process delivery) — each
  registered for `:receive` on its own Kind. They are genuinely different
  (passive inbox vs active process delivery) and are NOT merged. The
  internal `case kind_module` is retired.

  ## Where this lives (PR-2 vs PR-9)

  Conceptually this is the **agent domain's** transport seam (§3.3 — it
  hands DOWN to a flavor-blind `AgentBridge.deliver`). Physically it
  STAYS in `ezagent_domain_session` until PR-9 carves out
  `domain.agent`; the extraction in PR-2 was the action split, not the app
  move. PR-A (#53) then relocated the delivery mechanics into the agent
  domain — they now live in
  `Ezagent.ActionSet.Agent.Delivery.deliver_agent_receive/2` (no longer a
  session Behavior), cutting the last agent→session compile edge so PR-9
  can move `domain.agent` as a leaf. Pure message-body accessors are shared
  via `Ezagent.Message.Body` (core).

  ## What `agent.receive` does (extracted VERBATIM from the Agent branch)

  Builds a flavor-neutral `Ezagent.AgentBridge.Payload` from the message
  + ctx and delivers it via `Ezagent.AgentBridge`, self-healing a
  vanished bridge (cc / codex subprocess relaunch + rebind await). This
  is a same-process side effect (no slice state); the handler emits no
  effects (`{:ok, %{}, []}`). The bridge resolves the bound channel +
  per-flavor adapter; a missing bridge/adapter is best-effort (logged by
  AgentBridge), because `:receive` is a `:cast`.

  ## Slice ownership

  NONE. The Agent Kind carries no `:receive` slice — delivery is a live
  side effect, not durable state. (The agent's OWN durable state, e.g.
  the cc/codex bridge or the curl conversation, lives on its flavor
  Behavior, not here.) `reads_siblings([:sandbox])` is declared because
  the delivery helper resolves the agent's flavor from the sibling
  `:sandbox` slice (`ctx[:siblings][:sandbox]` →
  `Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox/1`) to pick the
  right AgentBridge adapter (cc / codex / …).

  ## Naming (§11 NP-1/NP-2/NP-3 audit)

  `Ezagent.ActionSet.Agent.Receive` — a domain module naming its own
  concept; the name tracks the single action's intent (`receive`) at the
  narrowest accurate scope (NP-1), in its own layer's vocabulary (NP-2),
  with a width that matches its one action (NP-3). No violation.
  """

  # lifecycle:state_slice_override
  #
  # codex P3 (PR-2): the macro would auto-derive `:receive` from the module
  # name, but `Entity.Agent` has no `:receive` slice — so the runtime would
  # fetch `%{}` and commit `Map.put(state, :receive, %{})`, leaving a durable
  # ORPHAN slice on snapshot-on-change Agents after the first inbound message.
  # Pin to `:session` — the historical receive-state slice key (the same slice
  # the pre-split Agent branch used, and that `User.Receive` pins to) — so no
  # snapshot-key migration is forced.
  #
  # PR-A (#53): the vestigial session-HOST behavior is no longer composed onto
  # `Entity.Agent` (an agent is a session MEMBER, never a host, so its
  # `:session` slice was always empty).
  # `Entity.Agent` therefore no longer materializes `:session`, so
  # `Ezagent.Kind.Snapshot.prune_orphan_slices/2` correctly drops the (empty)
  # `:session` slice from existing agent snapshots on cold-load. This handler
  # emits NO effects, so it read-commits the slice UNCHANGED — no write, no
  # re-created orphan. Net: byte-identical-minus-empty-`:session`; no migration.
  use Ezagent.Lifecycle, state_slice: :session
  # `:sandbox` — the delivery helper resolves the agent's flavor from it.
  # `:identity` (A2.2, spec R1.1/R2.3) — pre-load the agent's OWN held caps so the
  # in-handler `MemberReceive.authorize/1` reads the member-cap WITHOUT a
  # `GenServer.call` (no self-slice deadlock, no per-message cross-process read).
  reads_siblings([:sandbox, :identity])

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.ActionSet.Agent.Delivery
  alias Ezagent.Message.Body

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Deliver an inbound session message to this Agent via AgentBridge"
  )

  # --- :receive ----------------------------------------------------------

  @doc """
  Deliver an inbound session message to the live agent via AgentBridge
  (delegates to `Ezagent.ActionSet.Agent.Delivery.deliver_agent_receive/2`).

  Builds the flavor-neutral payload and pushes it through AgentBridge
  (self-healing a vanished bridge); a same-process side effect.

  ## Two transport classes — one flavor-blind handler

    * `:subprocess_ws` (cc / codex) → `deliver` returns `:ok`; the agent's
      reply is ASYNC (bridge → `session.send`). The handler emits NO
      effects (the Agent Kind has no receive slice).

    * `:in_process_sync` (curl, PR-6 §3.5 / §9 tension 3) → `deliver`
      returns `{:sync, result}` SYNCHRONOUSLY (`result` is the adapter's
      `{:ok, _}` / `{:error, _}`). The handler re-dispatches that result to
      the SAME agent URI's `:sync_result` action via a `{:dispatch, %Cmd{}}`
      effect, so the flavor's STATE Behavior (curl) persists the conversation
      + replies. The branch is on the `{:sync, _}` CLASS TAG, not the flavor
      name — `agent.receive` stays flavor-blind (any future
      `:in_process_sync` flavor whose Behavior owns a `:sync_result` action
      gets the same treatment), and a `:subprocess_ws` `{:error, :no_bridge}`
      is never mistaken for a sync result.

  ## KNOWN LIMITATION — `:in_process_sync` `:sync_result` ordering (codex round-2 P2)

  For the `:in_process_sync` class, this handler does the HTTP round-trip
  SYNCHRONOUSLY (blocking the Agent GenServer) but persists the conversation
  via a SEPARATE re-dispatched `:sync_result` `:cast`. That `:cast` is a
  post-commit DEFERRED dispatch (`Kind.DeferredDispatch.enqueue/1` →
  `send(self(), {:ezagent_run_deferred, …})`), so it lands at the BACK of the
  Agent's own mailbox.

  If TWO `:receive` casts are queued for the SAME curl agent, the mailbox
  evolves:

      [receive#1, receive#2]
      → run receive#1 (HTTP blocks) → commit → enqueue sync_result#1 at END
      [receive#2, sync_result#1]
      → run receive#2 (HTTP) — the adapter reads the SNAPSHOT conversation,
        which does NOT yet include receive#1's turns (sync_result#1 hasn't run)
      [sync_result#1, sync_result#2]
      → persist#1, then persist#2

  So prompt#2 is built from a STALE conversation snapshot (missing the user +
  assistant turns from message#1). The pre-fold `Behavior.CurlAgent.handle_receive/2`
  returned the conversation `{:set, …}` in the SAME `:receive` dispatch, so the
  state was committed before the next mailbox message could run — no interleave.

  ### Why this is a documented limitation and not fixed in PR-6

  A synchronous-ordering fix (persist the conversation IN THE SAME `:receive`
  dispatch) is blocked by the runtime's single-slice commit model. `agent.receive`
  is FLAVOR-BLIND and pins `state_slice: :session`; the conversation lives in the
  `:curl_agent` slice OWNED by `Behavior.CurlAgent`. The runtime commits ONLY the
  dispatched behavior's own slice (`Runtime.handle_dispatch` step 9:
  `put_in(state, [behavior.state_slice()], new_slice)`), and the effect grammar
  has no cross-slice / sibling-WRITE effect (`reads_siblings/0` is read-only;
  R10-2 makes a handler's `{:set, …}` atomic over exactly ONE slice). So
  `agent.receive` STRUCTURALLY cannot emit `{:set, :conversation, …}` into
  `:curl_agent` within its own dispatch. A clean in-cycle fix requires ONE of:

    1. **Per-instance/flavor behavior selection for `{Entity.Agent, :receive}`** —
       a curl-flavor `:receive` behavior bound on the `:curl_agent` slice that
       does HTTP→persist in one dispatch. Today `BehaviorRegistry.lookup/2`
       resolves `{Kind, action}` to a SINGLE global behavior; the per-instance
       `effective_set` gate only DENIES a scoped-out behavior, it does not SELECT
       among multiple behaviors claiming the same `{Kind, :receive}`. This is a
       registry/dispatch redesign.
    2. **A multi-slice (cross-behavior) write within one dispatch** — let a
       flavor-blind behavior emit the owning behavior's slice effects, applied +
       committed in the same cycle before the next mailbox message. This is an
       effect-grammar + commit-model redesign (breaks the single-slice atomicity
       invariant R10-2).
    3. **A runtime mailbox-ordering guarantee** that a self-targeted
       `:sync_result` `:cast` is applied BEFORE the next queued `:receive` — i.e.
       selective-receive / priority scheduling in `Kind.Server`. This is a
       scheduler redesign with broad blast radius.

  None lands cleanly inside PR-6 (the curl-as-flavor fold). Per the DEFER VALVE,
  the async path stays; the concurrency edge is captured by the
  `@tag :known_limitation` regression in
  `agent_receive_sync_result_ordering_test.exs`. PR-7 (which migrates curl
  snapshots onto `Entity.Agent` and deletes the legacy Kind) or a follow-up
  runtime PR is the right home for option 1 (the least-invasive of the three —
  flavor-selected `:receive` keeps the single-slice model intact).

  ### Practical exposure

  The window is "two inbound messages to the SAME curl agent before the first's
  HTTP completes." In the production chat topology a single user's turns to one
  agent are naturally serialized by the human round-trip; the edge is reachable
  under concurrent senders / scripted bursts to one curl agent. cc/codex
  (`:subprocess_ws`) are UNAFFECTED — their reply is async through the bridge and
  carries no in-process `:sync_result` re-dispatch.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    # Membership-cap unification A2.2 (spec R1.1/R2.3) — `:receive` is cap-EXEMPT;
    # THIS held-cap check is the sole authority, placed at the TOP of the SINGLE
    # entry for ALL agent flavors (cc / codex / hello / curl / native) — BEFORE
    # the bridge short-circuit (`Delivery.deliver_agent_receive/2`), so every
    # plugin agent is gated through one site (a plugin agent cannot bypass it —
    # there is no separate plugin `{Kind, :receive}`). A revoked/pending agent
    # holds no member-cap ⇒ denied IMMEDIATELY, its `:receive` never runs, its
    # credential is never spent.
    with :ok <- Ezagent.Session.MemberReceive.authorize(ctx) do
      do_handle_receive(msg, ctx)
    end
  end

  defp do_handle_receive(%Message{} = msg, ctx) do
    if self_message?(msg, ctx) do
      # codex P2 (PR-6) — loop guard. A routing rule targeting a curl agent by
      # LITERAL URI (not a magic token) skips the magic-token sender exclusion,
      # so the agent's OWN `session.send` reply gets delivered back to itself.
      # Without this guard, `agent.receive` would forward that self-message to
      # the `:in_process_sync` adapter → the curl agent calls the upstream LLM
      # API on its OWN reply → infinite loop. The pre-fold
      # `CurlAgent.handle_receive/2` ignored `msg.sender == self_uri`; restore
      # that here at the flavor-blind seam (it is correct for EVERY flavor — an
      # agent never re-processes its own outbound message).
      {:ok, %{ignored: :self_message}, []}
    else
      # AgentBridge PR-D / PR-6: keep receive flavor-neutral. Payload build +
      # self-healing bridge delivery live in `Ezagent.ActionSet.Agent.Delivery`
      # (agent domain). The CLASS-TAGGED delivery result decides whether we re-dispatch.
      case Delivery.deliver_agent_receive(msg, ctx) do
        :ok ->
          # :subprocess_ws — async reply through the bridge; nothing to do.
          {:ok, %{}, []}

        {:sync, flavor, sync_result} ->
          # :in_process_sync — re-dispatch the result into the flavor's
          # :sync_result Behavior to persist + reply.
          #
          # KNOWN LIMITATION (codex round-2 P2) — this re-dispatch is an async
          # post-commit `:cast` that lands at the BACK of this agent's mailbox,
          # so a second queued `:receive` runs against a STALE conversation
          # snapshot before sync_result#1 commits. A same-dispatch persist is
          # blocked by the single-slice commit model (`agent.receive` owns
          # `:session`, the conversation lives in `:curl_agent`). See the
          # moduledoc "KNOWN LIMITATION" section + the `:known_limitation`
          # regression for the precise blocker + the three redesign options.
          {:ok, %{}, [sync_result_effect(msg, ctx, flavor, sync_result)]}
      end
    end
  end

  # A message whose sender is THIS agent's own URI (instance-equal). Compared
  # on `Ezagent.URI.instance/1` so a literal-URI rule's echo matches regardless
  # of action/query-string differences.
  defp self_message?(%Message{sender: sender}, ctx) do
    case ctx[:self_uri] do
      %URI{} = self_uri -> same_instance?(sender, self_uri)
      _ -> false
    end
  end

  defp same_instance?(%URI{} = a, %URI{} = b),
    do: Ezagent.URI.instance(a) == Ezagent.URI.instance(b)

  defp same_instance?(a, %URI{} = b) when is_binary(a) and a != "" do
    Ezagent.URI.instance(Ezagent.URI.new!(a)) == Ezagent.URI.instance(b)
  rescue
    ArgumentError -> false
  end

  defp same_instance?(_, _), do: false

  # caps-data-ownership-v2 (SPEC #306 §7) — a Behavior with caps MUST declare
  # data_owner/1. `agent.receive` owns NO durable data (delivery is a live
  # side-effect; it pins `:session` only to read-commit it UNCHANGED). The
  # `:receive` cap is the system/router delivery authority, not a per-entity
  # data grant — so there is no owner to formalize.
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # Membership-cap unification A2.2 (spec R1.1/R2.3) — `:receive` is EXEMPT from
  # the CapBAC layer (no delivery-presented bearer cap). The in-handler
  # `MemberReceive.authorize/1` held-cap check is the SOLE authority.
  @doc "`:receive` is cap-exempt (authorized in-handler on the held member-cap, A2.2)."
  def cap_exempt_actions, do: [:receive]

  # Build the `{:dispatch, %Cmd{}}` that hands the `:in_process_sync`
  # delivery result to the agent's own `:sync_result` action.
  #
  # System-principal elimination (#154 甲-4) — the ambient
  # `system://chat-router` WILDCARD principal is DELETED. This is a pure
  # SELF-dispatch (the agent persists its OWN sync_result on its OWN
  # instance), so the agent presents its OWN narrow `:sync_result` self-cap
  # (`granted_by: self_uri`, a real entity — genuine self-authority;
  # provenance-only, the step-5.5 authorizer `granted_via_ctx_caps?`, never
  # routed through Grant). `kind`/`behavior` are `:any` because each agent
  # FLAVOR (cc/codex/echo/np/curl) declares its own `required_caps[:sync_result]`
  # behavior module — `:any` field-matches them all while `action`
  # (`:sync_result`) + `instance` (the agent's OWN URI) keep it
  # least-privilege: it authorizes only this agent's own sync_result.
  defp sync_result_effect(%Message{} = msg, ctx, flavor, sync_result) do
    self_uri = ctx[:self_uri]
    source_session = ctx[:caller]
    user_text = Body.body_text(msg.body)
    action = sync_result_action(flavor)

    target = Ezagent.URI.with_action(self_uri, action, action)

    cmd =
      Cmd.new(
        target,
        action,
        %{
          result: sync_result,
          source_session: source_session,
          user_text: user_text,
          in_msg_id: msg.id
        },
        %{
          caller: source_session,
          caps:
            MapSet.new([
              %Ezagent.Capability{
                Ezagent.Capability.cap(
                  :any,
                  :any,
                  action,
                  Ezagent.URI.instance(self_uri),
                  Ezagent.Capability.workspace_of(self_uri)
                )
                | granted_by: self_uri,
                  granted_at: DateTime.utc_now()
              }
            ]),
          reply: :ignore
        }
      )

    {:dispatch, cmd}
  end

  defp sync_result_action("cc-headless"), do: :cc_headless_sync_result
  # cc-custom (provider-profile) headless variant — same headless SDK sidecar,
  # same unique reply action; ONE clause serves every catalog profile.
  defp sync_result_action("cc-headless-custom"), do: :cc_headless_sync_result
  # DeepSeek provider variant of cc-headless — same headless SDK sidecar, same
  # unique reply action (it carries the `Ezagent.ActionSet.CcHeadlessAgent`
  # behavior); only the backend LLM differs. Without this clause the reply falls
  # to the default `:sync_result` (which curl claims globally) and is dropped.
  defp sync_result_action("cc-headless-deepseek"), do: :cc_headless_sync_result
  defp sync_result_action("py"), do: :py_sync_result
  # hello's in-process router flavor — a UNIQUE action so it is not shadowed by the
  # default `:sync_result` that `curl` claims globally on `Entity.Agent` (mirrors
  # the py / cc-headless unique-action pattern). Owned by `Behavior.HelloOrchestrator`.
  defp sync_result_action("hello"), do: :hello_sync_result
  defp sync_result_action(_), do: :sync_result
end
