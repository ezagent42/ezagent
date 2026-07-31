defmodule Ezagent.OperatorEvents do
  @moduledoc """
  The **one canonical write API** for operator-facing warnings and events
  (observability seam, 2026-07-31).

  ## Why this exists — the seam

  Before this module, operator-relevant conditions surfaced (or failed to
  surface) through three unrelated paths:

    * `Ezagent.Audit` — a telemetry *sink* fanning `[:ezagent, :invoke, …]`
      to `esr:audit:stream` + a durable row. Invocation-event-scoped.
    * `Ezagent.CCEvents` — a CC-agent-failure *ingestion adapter*
      (HTTP hook → `cc_events:stream`). Bypasses Invocation on purpose.
    * …and everything else was **silent**: e.g. a `DeliveryOutbox` row
      going `:dead` (capability delivery permanently abandoned) fired
      zero telemetry and zero alert — an operator had no way to know a
      capability never reached its target.

  There was no single place code could say "an operator should see this."
  `Ezagent.OperatorEvents.emit/1` **is** that place. Anything that wants
  to raise an operator-facing warning/event calls it — full stop.

  ## Relationship to `Audit` and `CCEvents` (consolidation — target state)

  `emit/1` is the **write** seam. The consolidation is delivered NOW at the
  API level (one write API); the wiring of the existing modules as its
  endpoints is a **deferred follow-up** — until then `Audit` and `CCEvents`
  remain independent streams and this is transitionally a third one. The
  target roles (see `docs/notes/2026-07-31-operator-events-seam.md`):

    * **`Audit` becomes a sink** (NOT YET WIRED). `emit/1` already fires
      `[:ezagent, :operator, :event]` telemetry — the same mechanism
      `CCEvents` uses for `[:ezagent, :cc_bridge, :event]` — so the
      follow-up only has to attach that event in `Audit` to persist a
      durable, queryable history, making Audit a subscriber to this seam
      rather than a peer stream.
    * **`CCEvents` becomes an ingestion adapter** (NOT YET WIRED). Its HTTP
      hook collapses to an `OperatorEvents.emit/1` call — one *source*
      feeding the canonical seam, not a parallel channel.

  The **live** delivery target is a single operator-gated topic
  (`topic/0`); the durable history is the (future) `Audit` sink. Callers do
  not pick a topic — the topic is an implementation detail of the seam.

  ## Operator-gating (task #187)

  `topic/0` is a GLOBAL, all-tenant operator-observability stream — the
  same trust class as `Audit.stream_topic/0` and `CCEvents.topic/0`. Only
  operator surfaces subscribe, and they gate delivery on
  `Ezagent.Identity.AdminAuthority.admin?/1` at BOTH subscribe-time and
  delivery-time (fail-closed). See `EzagentPluginWorld.WorldLive`.

  ## Contract

  `emit/1` validates + normalizes, then does two non-blocking ops:

    1. `Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic(),
       {:operator_event, event})` — live operator surfaces.
    2. `:telemetry.execute([:ezagent, :operator, :event], %{count: 1},
       event)` — the sink hook (Audit history, metrics).

  Both are best-effort observability, **failure-isolated independently**:
  `emit/1` never raises for a valid event, and a PubSub outage can neither
  escape into the emitter's caller nor suppress the telemetry sink. This
  matters because emitters run in fragile windows — e.g. the outbox
  `Sweeper` can attempt a `:dead` delivery before `EzagentCore.PubSub` is
  started, and PubSub can restart under a supervisor. An observability
  call must never crash the `Kind.Server` / outbox path that triggered it,
  so the outbox `:dead` emitter can call `warn/3` without guarding its own
  bookkeeping.
  """

  require Logger

  @topic "operator:events:stream"

  @severities [:info, :warning, :error]

  # Bounds on the fan-out payload. This is a GLOBAL stream: every operator
  # LiveView converts, encodes, and retains up to 20 events, so an oversized
  # or deeply-nested `meta`/`message` multiplies memory/CPU by the operator
  # count. The canonical API must not fan out unbounded user-derived payloads.
  @max_message_bytes 4_096
  @max_meta_bytes 8_192

  @typedoc "A normalized operator event."
  @type event :: %{
          severity: :info | :warning | :error,
          source: atom() | String.t(),
          message: String.t(),
          meta: map(),
          at: DateTime.t()
        }

  @doc "PubSub topic operator surfaces subscribe to (operator-gated)."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Allowed severities, in ascending order."
  @spec severities() :: [atom()]
  def severities, do: @severities

  @doc """
  Emit an operator event.

  `attrs` must carry `:severity` (`:info | :warning | :error`),
  `:source` (atom or non-empty string identifying the emitter), and
  `:message` (non-empty string). `:meta` (map, default `%{}`) carries a
  structured payload for the operator surface.

  Fan-out bounds (this is a GLOBAL, per-operator-socket stream): a message
  over #{@max_message_bytes} bytes is truncated and marked; a `meta` whose
  serialized size exceeds #{@max_meta_bytes} bytes is replaced with a
  `%{truncated: true, reason: :meta_too_large, approx_bytes: n}` marker.

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec emit(map()) :: {:ok, event()} | {:error, term()}
  def emit(attrs) when is_map(attrs) do
    with {:ok, severity} <- fetch_severity(attrs),
         {:ok, source} <- fetch_source(attrs),
         {:ok, message} <- fetch_message(attrs) do
      event = %{
        severity: severity,
        source: source,
        message: bound_message(message),
        meta: bound_meta(normalize_meta(Map.get(attrs, :meta))),
        at: DateTime.utc_now()
      }

      # Each endpoint is isolated so one failing cannot take down the other
      # or escape into the caller.
      safe_broadcast(event)
      safe_telemetry(event)

      {:ok, event}
    end
  end

  # Live operator surface. Best-effort: a broadcast on a not-yet-started or
  # restarting `EzagentCore.PubSub` raises `unknown registry` — that must
  # not propagate into the emitter (e.g. the outbox `:dead` path running
  # under the Sweeper before PubSub is up).
  defp safe_broadcast(event) do
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, @topic, {:operator_event, event})
  rescue
    error -> Logger.warning("OperatorEvents: PubSub broadcast failed: #{inspect(error)}")
  catch
    kind, reason -> Logger.warning("OperatorEvents: PubSub broadcast #{kind}: #{inspect(reason)}")
  end

  # Sink hook (Audit history, metrics). `:telemetry.execute/3` already traps
  # handler exceptions, but isolate here too so the seam's own contract holds
  # regardless of any future execute-time change.
  defp safe_telemetry(event) do
    :telemetry.execute([:ezagent, :operator, :event], %{count: 1}, event)
  rescue
    error -> Logger.warning("OperatorEvents: telemetry emit failed: #{inspect(error)}")
  catch
    kind, reason -> Logger.warning("OperatorEvents: telemetry emit #{kind}: #{inspect(reason)}")
  end

  @doc "Convenience for `emit/1` with `severity: :warning`."
  @spec warn(atom() | String.t(), String.t(), map()) :: {:ok, event()} | {:error, term()}
  def warn(source, message, meta \\ %{}),
    do: emit(%{severity: :warning, source: source, message: message, meta: meta})

  @doc "Convenience for `emit/1` with `severity: :error`."
  @spec error(atom() | String.t(), String.t(), map()) :: {:ok, event()} | {:error, term()}
  def error(source, message, meta \\ %{}),
    do: emit(%{severity: :error, source: source, message: message, meta: meta})

  @doc "Convenience for `emit/1` with `severity: :info`."
  @spec info(atom() | String.t(), String.t(), map()) :: {:ok, event()} | {:error, term()}
  def info(source, message, meta \\ %{}),
    do: emit(%{severity: :info, source: source, message: message, meta: meta})

  # --- validation / normalization ------------------------------------------

  defp fetch_severity(attrs) do
    case Map.get(attrs, :severity) do
      s when s in @severities -> {:ok, s}
      s when is_binary(s) -> string_severity(s)
      _ -> {:error, {:invalid_severity, "must be one of #{inspect(@severities)}"}}
    end
  end

  defp string_severity(s) do
    case Enum.find(@severities, &(Atom.to_string(&1) == s)) do
      nil -> {:error, {:invalid_severity, "must be one of #{inspect(@severities)}"}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_source(attrs) do
    case Map.get(attrs, :source) do
      a when is_atom(a) and not is_nil(a) -> {:ok, a}
      s when is_binary(s) and byte_size(s) > 0 -> {:ok, s}
      _ -> {:error, {:missing_field, :source}}
    end
  end

  defp fetch_message(attrs) do
    case Map.get(attrs, :message) do
      s when is_binary(s) and byte_size(s) > 0 -> {:ok, s}
      _ -> {:error, {:missing_field, :message}}
    end
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  # --- fan-out payload bounds -----------------------------------------------

  # Cap the message at a byte length, trimmed to a valid-UTF-8 prefix (so a
  # multi-byte codepoint is never split) and marked. Under the cap → unchanged.
  defp bound_message(message) when byte_size(message) <= @max_message_bytes, do: message

  defp bound_message(message) do
    valid_utf8_prefix(binary_part(message, 0, @max_message_bytes)) <> "…[truncated]"
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      # binary_part may have cut mid-codepoint; drop trailing bytes until valid
      # (at most 3 iterations for UTF-8, terminating at "").
      valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  # Reject an oversized `meta` (replace with a marker) rather than fan a
  # multi-MB / deeply-nested payload out to every operator socket. Serialized
  # size via `term_to_binary/1` (never raises; grows with both breadth and
  # depth) is a cheap proxy that also bounds nesting.
  defp bound_meta(meta) do
    approx_bytes = meta |> :erlang.term_to_binary() |> byte_size()

    if approx_bytes > @max_meta_bytes do
      %{truncated: true, reason: :meta_too_large, approx_bytes: approx_bytes}
    else
      meta
    end
  end
end
