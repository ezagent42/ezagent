defmodule Ezagent.Email.Binding do
  @moduledoc """
  #88 PR-1 (SPEC §4.2) — Email Binding for the generic ExternalMirror
  Domain. Modeled on `EzagentPluginFeishu.FeishuChatBinding`.

  Stateful per-target transport — one binding instance owns the publish
  loop to ONE bound email address (`target_id`). The
  `Ezagent.Entity.ExternalMirrorWorker` Kind is the GenServer skeleton;
  this module implements the transport callbacks.

  ## Verification gate (PR-2 — DURABLE, server-owned)

  `init/1` HARD-CODES `verification_status: :pending_verification` as a
  forgery-safe in-memory DEFAULT — it NEVER reads the field from `opts`,
  because the per-binding Worker forwards caller-controlled `opts` into
  `init/1` unfiltered. But the in-memory value is NO LONGER the gate.
  `publish/2` reads the DURABLE, server-owned status from
  `Ezagent.Email.InboundBinding.verified?/1` (keyed by `binding_row_id`)
  at publish time. This is what lets the web confirm path — which can't
  reliably reach a possibly-cold Worker — be authoritative (SPEC §4.4
  "status readable without a live Worker"), and the inbound poller reads
  the same durable status. A binding with no recorded inbound-meta row, or
  one still `pending_verification`, reads as NOT verified → refuse
  (`{:error, :not_verified, state}`, recoverable). Status is flipped to
  `verified` ONLY by `InboundBinding`'s token-confirm path, NEVER from
  caller opts — the consent hole stays closed with no permissive default.

  ## Durable threading (HIGH 5)

  `publish/2` computes the thread key
  `BindingRow.row_id(session_uri, "email", target_id)` from the
  SERVER-STAMPED `payload.session_uri` (the Adapter read it off
  `msg.session_uri`; not caller-controllable), loads
  `Ezagent.Email.ThreadState`, mints this message's `Message-ID`, sets
  `In-Reply-To` (the immediate parent) + a GROWING `References` chain
  (RFC 5322 full chain), sends, then persists the advanced thread state.
  Restart-safe: thread state is durable, so a Worker restart reloads the
  chain rather than starting a new thread.

  ## Recoverable vs raise (HIGH 3)

  - Transient send failure (`:mail_not_configured`, conn refused, timeout,
    relay reject) → `{:error, reason, new_state}` (recoverable; the Worker
    logs + carries state, retries on the next slice change, NO crash).
  - Invariant violation (durable thread-state write fails after the mail
    went out, or `payload.session_uri` missing/unparseable) → RAISE
    (let-it-crash; PerBindingSupervisor restarts). One chat send = one
    email, so there is NO partial-publish RAISE branch (unlike Feishu).
  """

  @behaviour Ezagent.ExternalMirror.Binding

  require Logger

  alias Ezagent.Email.{Adapter, InboundBinding, ThreadState}
  alias Ezagent.ExternalMirror.BindingRow

  @impl Ezagent.ExternalMirror.Binding
  def adapter_module, do: Ezagent.Email.Adapter

  @impl Ezagent.ExternalMirror.Binding
  def init({target_id, _adapter, opts}) when is_binary(target_id) do
    if valid_address?(target_id) do
      {:ok,
       %{
         target_id: target_id,
         opts: opts,
         # HARD-CODED — never read from caller opts (see moduledoc).
         verification_status: :pending_verification,
         publish_count: 0,
         error_count: 0
       }}
    else
      {:error, {:invalid_target_id, target_id}}
    end
  end

  def init({other, _adapter, _opts}), do: {:error, {:invalid_target_id, other}}

  @impl Ezagent.ExternalMirror.Binding
  def publish(%{} = payload, %{} = state) do
    session_uri = normalize_session_uri!(Map.get(payload, :session_uri))
    binding_row_id = BindingRow.row_id(session_uri, "email", state.target_id)

    if InboundBinding.verified?(binding_row_id) do
      do_publish(payload, state, session_uri, binding_row_id)
    else
      # Refuse to send to an unverified address. DURABLE gate (PR-2): the
      # server-owned status read by `binding_row_id` is authoritative — the
      # in-memory `state.verification_status` is only a safe default.
      # Recoverable: the Worker logs + carries state.
      Logger.info(
        "Email.Binding: refusing publish — binding not verified " <>
          "(binding_row_id=#{binding_row_id}, target=#{state.target_id})"
      )

      {:error, :not_verified, state}
    end
  end

  defp do_publish(%{} = payload, %{} = state, session_uri, binding_row_id) do
    ts = ThreadState.load(binding_row_id)

    new_mid = mint_message_id()
    in_reply_to = ts && ts.last_message_id
    # RFC 5322 §3.6.4: `References` lists ONLY the PRIOR messages in the
    # thread — NOT the current message's own `Message-ID`. So we SEND the
    # prior chain (nil on the root → no header), and PERSIST the prior chain
    # grown by `new_mid` for the next outbound.
    prior_chain = prior_references(ts)
    next_chain = grow_chain(prior_chain, new_mid)

    send_opts =
      [
        html: payload[:html],
        message_id: Adapter.sanitize_header_value!(new_mid)
      ]
      |> maybe_put(:in_reply_to, in_reply_to && Adapter.sanitize_header_value!(in_reply_to))
      |> maybe_put(:references, prior_chain && Adapter.sanitize_header_value!(prior_chain))

    subject = Adapter.sanitize_header_value!(payload.subject)

    case Ezagent.Email.send(state.target_id, subject, payload.text, send_opts) do
      {:ok, _} ->
        persist_thread!(binding_row_id, ts, new_mid, next_chain, session_uri)
        {:ok, %{state | publish_count: state.publish_count + 1}}

      {:error, reason} ->
        # Transient — recoverable per HIGH 3.
        Logger.warning(
          "Email.Binding publish failed (recoverable): target=#{state.target_id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason, %{state | error_count: state.error_count + 1}}
    end
  end

  @impl Ezagent.ExternalMirror.Binding
  def terminate(_reason, _state), do: :ok

  # ----- internals -----------------------------------------------------------

  # Persist the advanced thread state. The durable write MUST succeed once the
  # mail has been sent — a failure here is an invariant violation (the human
  # received a mail whose Message-ID we then lost, breaking the next reply's
  # threading). RAISE (let-it-crash) rather than silently drop.
  defp persist_thread!(binding_row_id, ts, new_mid, references, session_uri) do
    root = (ts && ts.root_message_id) || new_mid
    workspace_uri = workspace_uri_for!(session_uri)

    case ThreadState.upsert(binding_row_id, %{
           root_message_id: root,
           last_message_id: new_mid,
           references_chain: references,
           workspace_uri: workspace_uri
         }) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        raise "Email.Binding: durable thread-state write failed AFTER send " <>
                "(binding_row_id=#{binding_row_id}): #{inspect(reason)}"
    end
  end

  # The PRIOR References chain to SEND in this message's `References` header
  # (RFC 5322 §3.6.4 — prior messages only). `nil` on the thread root (no
  # prior messages → no header). For an existing thread it is the persisted
  # `references_chain` (which already includes every prior Message-ID,
  # including the root); fall back to `root_message_id` for a thread whose
  # chain column predates this field.
  defp prior_references(nil), do: nil

  defp prior_references(%ThreadState{references_chain: chain})
       when is_binary(chain) and chain != "",
       do: chain

  defp prior_references(%ThreadState{root_message_id: root})
       when is_binary(root) and root != "",
       do: root

  defp prior_references(_ts), do: nil

  # The chain to PERSIST for the NEXT outbound: prior chain grown by this
  # message's id (so the next message's `References` lists this one too).
  defp grow_chain(nil, new_mid), do: new_mid
  defp grow_chain(prior, new_mid) when is_binary(prior), do: prior <> " " <> new_mid

  defp mint_message_id do
    "<" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)) <> "@ezagent.chat>"
  end

  defp normalize_session_uri!(%URI{} = uri), do: uri
  defp normalize_session_uri!(s) when is_binary(s) and s != "", do: Ezagent.URI.new!(s)

  defp normalize_session_uri!(other) do
    raise "Email.Binding: payload missing a usable session_uri (got #{inspect(other)}) — " <>
            "cannot compute the durable thread key"
  end

  defp workspace_uri_for!(%URI{} = session_uri) do
    Ezagent.Persistence.workspace_uri_for!(session_uri)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp valid_address?(addr) when is_binary(addr) do
    Regex.match?(~r/^[^\s@\x00-\x1f]+@[^\s@\x00-\x1f]+\.[^\s@\x00-\x1f]+$/, addr)
  end
end
