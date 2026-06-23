defmodule Ezagent.Email.Binding do
  @moduledoc """
  #88 PR-1 (SPEC §4.2) — Email Binding for the generic ExternalMirror
  Domain. Modeled on `EzagentPluginFeishu.FeishuChatBinding`.

  Stateful per-target transport — one binding instance owns the publish
  loop to ONE bound email address (`target_id`). The
  `Ezagent.Entity.ExternalMirrorWorker` Kind is the GenServer skeleton;
  this module implements the transport callbacks.

  ## Verification gate (PR-1 = production-inert until PR-2)

  `init/1` HARD-CODES `verification_status: :pending_verification` — it
  NEVER reads the field from `opts`, because the per-binding Worker forwards
  caller-controlled `opts` into `init/1` unfiltered, so trusting an
  `opts`-supplied status would let a bind-capable caller forge `:verified`
  and email an unconsented address. `publish/2` refuses to send unless the
  status is `:verified`. NOTHING in PR-1 mints `:verified` — that is the
  async bind-time verification handshake landing in PR-2 (a server-owned
  status column updated only by the token-confirm flow). So PR-1 outbound
  only fires in tests (which construct the state map directly); in
  production no email goes out until PR-2 lands. This closes the consent
  hole WITHOUT a permissive default.

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

  alias Ezagent.Email.{Adapter, ThreadState}
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
  def publish(%{} = _payload, %{verification_status: status} = state) when status != :verified do
    # Refuse to send to an unverified address. Recoverable: the Worker logs +
    # carries state. In PR-1 this is the steady state for all production
    # bindings (nothing mints :verified yet).
    Logger.info(
      "Email.Binding: refusing publish — binding not verified " <>
        "(status=#{inspect(status)}, target=#{state.target_id})"
    )

    {:error, :not_verified, state}
  end

  def publish(%{} = payload, %{verification_status: :verified} = state) do
    session_uri = normalize_session_uri!(Map.get(payload, :session_uri))
    binding_row_id = BindingRow.row_id(session_uri, "email", state.target_id)
    ts = ThreadState.load(binding_row_id)

    new_mid = mint_message_id()
    in_reply_to = ts && ts.last_message_id
    references = grow_references(ts, new_mid)

    send_opts =
      [
        html: payload[:html],
        message_id: Adapter.sanitize_header_value!(new_mid)
      ]
      |> maybe_put(:in_reply_to, in_reply_to && Adapter.sanitize_header_value!(in_reply_to))
      |> maybe_put(:references, references && Adapter.sanitize_header_value!(references))

    subject = Adapter.sanitize_header_value!(payload.subject)

    case Ezagent.Email.send(state.target_id, subject, payload.text, send_opts) do
      {:ok, _} ->
        persist_thread!(binding_row_id, ts, new_mid, references, session_uri)
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

  # Grow the RFC 5322 References chain (full chain, not root+last). First send
  # → just this Message-ID; subsequent → prior chain <> " " <> new id.
  defp grow_references(nil, new_mid), do: new_mid

  defp grow_references(%ThreadState{references_chain: chain}, new_mid)
       when is_binary(chain) and chain != "",
       do: chain <> " " <> new_mid

  defp grow_references(%ThreadState{root_message_id: root}, new_mid)
       when is_binary(root) and root != "",
       do: root <> " " <> new_mid

  defp grow_references(_ts, new_mid), do: new_mid

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
