defmodule Ezagent.Behavior.Echo do
  @moduledoc """
  Echo Behavior — `:say` returns the message; `:receive` echoes inbound
  chat messages back to the originating session.

  ## Phase B migration (2026-05-29) — Lifecycle API

  Migrated from `use Ezagent.Behavior` to `use Ezagent.Lifecycle`
  per SPEC `2026-05-29-lifecycle-hooks-design.md` §2.3 (the simple,
  no-transients case — same shape as the reference `CurlAgent`
  conversion). The CQRS engine (slice / invocation / snapshot) is
  hidden behind two state containers + lifecycle moments:

  - `init_slice/1` → `create/1` builds the PERSISTENT `state`.
  - There are NO transients (no PID / ETS / port / subprocess /
    monitor), so `activate/2` is the macro-injected no-op default —
    omitted here.
  - `handle_<action>/2` bodies are byte-identical (effects already
    declarative from the Phase 2-g new-contract migration; the only
    surface is `ctx[:read]` which the Lifecycle macro keeps).

  Earlier (Phase 2-g r3, 2026-05-28) this Behavior was already on the
  declarative `action/3` + `handle_<action>/2` + effects contract:

  - `:set` effect — slice writes (replacing `%{slice | k: v}` in-place
    mutation)
  - `:dispatch` effect — outbound chat reply (replacing
    `Invocation.dispatch/1` side effect inside invoke)
  - `required_caps/0` is still manually exported to preserve the
    kind axis `:echo`. The macro-derived legacy callback would use
    `:any`, which would silently downgrade cap precision.

  The auto-derived `state_slice/0` (last module segment `Echo` →
  `:echo`) equals the historical snapshot key, so NO `state_slice:`
  override is needed (SPEC §5 step 2 / §7 OQ-7).

  ## Actions

  - `:say` — programmatic invoke. Caller passes `%{msg: "..."}`; returns
    `%{echo: msg}`. Slice tracks `count` + `last_msg`.
  - `:receive` — chat fan-out hook. Echo Kind is registered on
    `BehaviorRegistry` for `:receive` so the Session's `chat.send`
    fan-out reaches it. On receive, build an "echo: <text>" reply
    Message and dispatch `chat.send` back to the originating session.

  ## Slice shape

      %{count: integer, last_msg: nil | string}

  `count` increments on `:say` AND on `:receive`. `last_msg` captures
  the most recent string observed by either action.

  ## Loop safety

  When `:receive` fires `chat.send` back to the session, the session's
  `Resolver.resolve/4` excludes the message sender from fan-out. Since
  echo's reply sender is the echo agent's URI, the reply does not loop
  back to the echo agent.
  """

  use Ezagent.Lifecycle

  alias Ezagent.{Cmd, Message}

  action :say,
    args: %{msg: :string},
    returns: %{echo: :string},
    caps: [:say],
    modes: [:call, :cast],
    description: "Echo a string back to the caller"

  action :receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "Reply to an inbound chat message with an \"echo: <text>\" line"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Echo is registered on Entity.Echo Kind (type_name :echo) — kind axis
  # is `:echo`. Manually exported to override the macro's `:any` default.
  def required_caps do
    %{
      say: Ezagent.Capability.cap(:echo, __MODULE__, :say),
      receive: Ezagent.Capability.cap(:echo, __MODULE__, :receive)
    }
  end

  # The auto-derived slice key for `Ezagent.Behavior.Echo` is the
  # underscored last segment `Echo` → `:echo`, EXACTLY the pre-Lifecycle
  # `state_slice/0`. The snapshot-compat key is preserved with no
  # explicit override (SPEC §5 step 2 / §7 OQ-7) — the hand-rolled
  # `def state_slice, do: :echo` is gone.

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build the initial
  # PERSISTENT `state` once, on first-ever existence. No transients
  # here (count + last_msg both survive restart), so `activate/2` is the
  # macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{count: 0, last_msg: nil}}

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract — unchanged by Lifecycle migration)
  # ---------------------------------------------------------------

  def handle_say(%{msg: msg}, ctx) when is_binary(msg) do
    cur_count = ctx[:read].(:count, 0)
    new_count = cur_count + 1

    {:ok, %{echo: msg},
     [
       {:set, :count, new_count},
       {:set, :last_msg, msg}
     ]}
  end

  # `:receive` — Session's chat fan-out dispatches `chat.receive` per
  # member; Echo's handler builds + dispatches an "echo: <text>" reply
  # back to the originating session. The reply is fire-and-forget
  # (`mode: :cast`, `reply: :ignore`).
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    original_text = extract_text(msg.body)

    cur_count = ctx[:read].(:count, 0)
    new_count = cur_count + 1

    base_effects = [
      {:set, :count, new_count},
      {:set, :last_msg, original_text}
    ]

    # --- Loop-amplification safety (V1 stress-test plan §7) -------------
    {hop, turn_cap} = stress_hop(msg.body)

    reply_allowed? =
      case {hop, turn_cap} do
        {nil, _} -> true
        {_, nil} -> true
        {h, cap} when is_integer(h) and is_integer(cap) -> h < cap
        _ -> true
      end

    self_uri = Map.get(ctx, :self_uri)
    session_uri = session_uri_from_caller(ctx)

    effects =
      case {reply_allowed?, session_uri, self_uri} do
        {false, _, _} ->
          base_effects

        {true, nil, _} ->
          base_effects

        {true, _, nil} ->
          base_effects

        {true, %URI{} = session, %URI{} = agent_uri} ->
          reply_text = "echo: #{original_text}"

          next_meta =
            case hop do
              nil -> nil
              h -> %{"hop" => h + 1, "turn_cap" => turn_cap}
            end

          reply_body =
            case next_meta do
              nil -> %{text: reply_text, attachments: []}
              meta -> %{text: reply_text, attachments: [], meta: meta}
            end

          reply_msg = Message.new(agent_uri, reply_body, ref_id: msg.id)
          target = Ezagent.URI.with_action(session, :chat, :send)

          cmd =
            Cmd.new(target, :send, %{message: reply_msg}, %{
              caller: agent_uri,
              # SPEC caps-cleanup-v1 §4.4 — agent reply path runs under
              # the `system://chat-reply` principal.
              caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
              reply: :ignore
            })

          base_effects ++ [{:dispatch, cmd}]
      end

    {:ok, %{}, effects}
  end

  # Body comes back with either atom or string keys depending on whether
  # it was freshly constructed or loaded from MessageStore (Ecto :map
  # column → JSON-decoded). Match either.
  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  # Extract the stress-test `{hop, turn_cap}` from a message body's
  # `meta` map. Returns `{nil, nil}` for any non-stress message (the
  # production case). Key shape is tolerant of atom or string keys.
  defp stress_hop(%{meta: %{} = m}), do: meta_pair(m)
  defp stress_hop(%{"meta" => %{} = m}), do: meta_pair(m)
  defp stress_hop(_), do: {nil, nil}

  defp meta_pair(m) do
    hop = m["hop"] || m[:hop]
    cap = m["turn_cap"] || m[:turn_cap]
    {hop, cap}
  end

  # ctx.caller is the dispatching principal — for Session→member fan-out
  # it's the session URI.
  defp session_uri_from_caller(%{caller: %URI{} = u}), do: u

  defp session_uri_from_caller(%{caller: s}) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the nil fallback for malformed caller URI.
    try do
      Ezagent.URI.new!(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp session_uri_from_caller(_), do: nil

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): admin-only Behavior —
  # no per-entity owner; only bootstrap admin grants via §5.2 admin
  # branch.
  def data_owner(_), do: :no_owner
end
