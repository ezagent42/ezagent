defmodule Ezagent.Email.Inbound do
  @moduledoc """
  Inbound email poll loop for the email ExternalMirror adapter
  (#88 PR-2 / SPEC §4.5). Email has no push webhook, so this supervised
  GenServer periodically pulls the Cloudflare Email Worker inbox
  (`Ezagent.Email.inbox/1`) and, for each fetched message, in order:

  1. **Loop/bounce guard** (`Inbound.Guard.accept_for_injection?/1`) —
     reject + `DELETE` (do NOT inject) bounces / auto-replies / bulk. FIRST,
     so a bounce of our own outbound never re-enters as fresh inbound.
  2. **Authority decision** — `Inbound.Authority` freshly joins the email
     projection to its durable ExternalMirror binding, verifies every scope
     axis, and authenticates the current sender. Deterministic denial logs +
     `DELETE`; reader/signing infrastructure failure retains the item.
  4. **Dedup** — a deterministic message id
     `hash(session_uri <> "/" <> normalized Message-ID)` (the
     `BindingRow.row_id` 24-hex shape) so a re-delivered poll cannot
     double-inject (`MessageStore` `on_conflict: :nothing`).
  5. **Inject** — dispatch `<session_uri>?action=session.send` (mode
     `:call`) under the restricted synthetic participant issued by
     `Inbound.Authority`, with `body._email_origin = true` (self-echo guard).
  6. **Update threading** — record the human's `Message-ID` as the next
     `In-Reply-To` target (durable `ThreadState`).
  7. **`DELETE` only AFTER a successful inject** (at-least-once; the
     deterministic id makes a pre-DELETE re-poll idempotent).

  ## Seams (for tests + production)

  - `:poll_interval_ms` (app env, default 30s) — timer period.
  - `:inbox_fun` / `:delete_fun` (app env) — default to `Ezagent.Email.inbox/1`
    and `Ezagent.Email.delete/1`; injected in tests.
  - `:dispatch_fun` (app env) — default `Ezagent.Invocation.dispatch/1`;
    injected so unit tests need not boot a live Session Kind.
  - `:authority_fun` is a per-call test seam for result finalization; production
    always defaults to `Inbound.Authority.issue/1`.

  `process_record/2` is the per-record pipeline, called by the loop AND
  directly by tests. It returns `{:injected, msg_id} | {:skipped, reason} |
  {:error, reason}`.
  """

  use GenServer

  require Logger

  alias Ezagent.Email.ThreadState
  alias Ezagent.Email.Inbound.{Authority, Guard}

  @default_interval_ms 30_000

  # ----- GenServer -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    poll_once()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_poll do
    Process.send_after(self(), :poll, poll_interval_ms())
  end

  @doc """
  Run one poll cycle: pull the inbox, process every record. Public so an
  operator / test can trigger a cycle without waiting for the timer.
  """
  @spec poll_once() :: :ok
  def poll_once do
    case inbox_fun().([]) do
      {:ok, records} when is_list(records) ->
        Enum.each(records, &process_record(&1, []))
        :ok

      {:error, reason} ->
        Logger.warning("Email.Inbound: inbox pull failed (recoverable): #{inspect(reason)}")
        :ok
    end
  end

  # ----- per-record pipeline -------------------------------------------------

  @doc """
  Process one CF-Worker inbox record. `opts` may inject `:dispatch_fun` /
  `:delete_fun` for tests (else app-env defaults). Returns
  `{:injected, msg_id} | {:skipped, reason} | {:error, reason}`.
  """
  @spec process_record(map(), keyword()) ::
          {:injected, String.t()} | {:skipped, atom()} | {:error, term()}
  def process_record(rec, opts \\ []) when is_map(rec) do
    key = Map.get(rec, "key")

    with :ok <- Guard.accept_for_injection?(rec) |> reject_to_skip() do
      case authority_fun(opts).(rec) do
        {:ok, decision} ->
          inject_and_finalize(rec, decision, key, opts)

        {:reject, reason} ->
          Logger.info("Email.Inbound: rejecting #{inspect(key)} — #{reason}")
          delete_item(key, opts)
          {:skipped, reason}

        {:retry, reason} ->
          Logger.warning(
            "Email.Inbound: authority unavailable for #{inspect(key)} " <>
              "(retained for retry): #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      {:skip, reason} ->
        # A guard/auth/address failure → DELETE without injecting (no bounce
        # in v1), so a rejected message never re-enters on the next poll.
        Logger.info("Email.Inbound: rejecting #{inspect(key)} — #{reason}")
        delete_item(key, opts)
        {:skipped, reason}
    end
  end

  defp inject_and_finalize(rec, decision, key, opts) do
    session_uri = decision.session_uri
    msg_id = deterministic_id(session_uri, Map.get(rec, "messageId"))

    case dispatch_inbound(
           rec,
           session_uri,
           msg_id,
           decision.principal_uri,
           decision.caps,
           opts
         ) do
      :ok ->
        update_inbound_threading(decision.binding_row_id, rec, session_uri)
        # DELETE only AFTER a successful inject (at-least-once; the
        # deterministic id makes a pre-DELETE re-poll idempotent).
        delete_item(key, opts)
        {:injected, msg_id}

      {:error, reason} ->
        # Inject failed — do NOT delete; the next poll retries (the
        # deterministic id dedups if a partial write landed).
        Logger.warning(
          "Email.Inbound: inject failed for #{inspect(key)} (retained for retry): " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp dispatch_inbound(rec, session_uri, msg_id, principal_uri, caps, opts) do
    body = %{
      text: Map.get(rec, "text") || "",
      attachments: [],
      _email_origin: true
    }

    msg = Ezagent.Message.new(principal_uri, body, id: msg_id)
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: principal_uri, caps: caps, reply: :sync},
      origin: :authenticated_external
    }

    case dispatch_fun(opts).(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Record the human's Message-ID as the next In-Reply-To target so the
  # agent's reply threads under it (durable; reuses ThreadState). Best-effort
  # — a threading-update failure must not block the (already-injected)
  # message; log + continue.
  defp update_inbound_threading(binding_row_id, rec, session_uri) do
    human_mid = rec |> Map.get("messageId") |> normalize_message_id()

    if human_mid != "" do
      ts = ThreadState.load(binding_row_id)
      root = (ts && ts.root_message_id) || human_mid
      chain = grow_chain(ts && ts.references_chain, root, human_mid)

      case ThreadState.upsert(binding_row_id, %{
             root_message_id: root,
             last_message_id: human_mid,
             references_chain: chain,
             workspace_uri: Ezagent.Persistence.workspace_uri_for!(session_uri)
           }) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Email.Inbound: thread-state update failed for #{binding_row_id} " <>
              "(message already injected): #{inspect(reason)}"
          )
      end
    end
  end

  # ----- helpers -------------------------------------------------------------

  # Deterministic message id from (session, normalized Message-ID) — the same
  # SHA-256-truncated 24-hex shape BindingRow.row_id/3 uses. A re-delivered
  # poll injects the SAME id → MessageStore on_conflict: :nothing no-ops.
  @doc false
  @spec deterministic_id(URI.t(), String.t() | nil) :: String.t()
  def deterministic_id(%URI{} = session_uri, message_id) do
    norm = normalize_message_id(message_id)

    :crypto.hash(:sha256, URI.to_string(session_uri) <> "/" <> norm)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  defp normalize_message_id(nil), do: ""

  defp normalize_message_id(mid) when is_binary(mid) do
    mid
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.downcase()
  end

  defp grow_chain(nil, root, human_mid) when root == human_mid, do: human_mid
  defp grow_chain(nil, root, human_mid), do: root <> " " <> human_mid

  defp grow_chain(chain, _root, human_mid) when is_binary(chain),
    do: chain <> " " <> human_mid

  defp reject_to_skip(:ok), do: :ok
  defp reject_to_skip({:reject, reason}), do: {:skip, reason}

  defp authority_fun(opts), do: Keyword.get(opts, :authority_fun, &Authority.issue/1)

  defp delete_item(nil, _opts), do: :ok

  defp delete_item(key, opts) when is_binary(key) do
    case delete_fun(opts).(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Email.Inbound: DELETE #{key} failed: #{inspect(reason)}")
    end
  end

  # ----- seams (app env + per-call opts) -------------------------------------

  defp poll_interval_ms,
    do:
      Application.get_env(:ezagent_plugin_email, :inbound_poll_interval_ms, @default_interval_ms)

  defp inbox_fun,
    do: Application.get_env(:ezagent_plugin_email, :inbound_inbox_fun, &Ezagent.Email.inbox/1)

  defp dispatch_fun(opts) do
    Keyword.get(opts, :dispatch_fun) ||
      Application.get_env(
        :ezagent_plugin_email,
        :inbound_dispatch_fun,
        &Ezagent.Invocation.dispatch/1
      )
  end

  defp delete_fun(opts) do
    Keyword.get(opts, :delete_fun) ||
      Application.get_env(:ezagent_plugin_email, :inbound_delete_fun, &Ezagent.Email.delete/1)
  end
end
