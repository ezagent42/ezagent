defmodule Ezagent.EventLog do
  @moduledoc """
  `Ezagent.EventLog` — framework-internal event store (SPEC §5.1).

  See `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §5.1 for the design. Phase 1B (this module) introduces the synchronous
  append + replay-stream API that the Router and `Ezagent.Kind.StateRebuilder`
  will consume in subsequent phases.

  ## What this wraps

  The existing `invocations` table (see migration
  `20260515160000_phase1_audit_dlq_snapshots.exs` rebuilt by
  `20260601000000_phase9_pr6_workspace_uri_columns.exs`). Column
  mapping for an event row:

  | Event field        | Column         |
  |--------------------|----------------|
  | `event_id`         | `id`           |
  | `aggregate_uri`    | `target`       |
  | `event_name`       | `action`       |
  | `payload`          | `args` (JSON)  |
  | `caller`           | `caller`       |
  | `workspace_uri`    | `workspace_uri`|
  | `trace_id`         | `trace_id`     |
  | `inserted_at`      | `inserted_at`  |

  ## Phase 1B vs `Ezagent.Audit.Writer` — co-existence

  The existing `Ezagent.Audit.Writer` still writes the `invocations`
  table from telemetry handlers (async batch). `EventLog.append/4` is
  the NEW Phase 1 write path used by the Router for `{:emit, …}`
  effects. Both writers target the same table — the existing telemetry
  rows show as events with `action ∈ {"snapshot.written", …}` and the
  new emit-effect rows show as events with `action = <event_name>`.
  They co-exist until Phase 3 cleanup removes the telemetry-derived
  rows in favor of explicit `{:emit, …}` effects.

  ## Framework-internal — NO plugin contact (SPEC §11 grep gate)

  **Plugin code MUST NOT import `Ezagent.EventLog`.** Plugin handlers
  emit events declaratively via `{:emit, event_name, payload}`
  effects; the Router calls `append/4`. Reading events for replay
  happens via `Ezagent.Kind.StateRebuilder` (Phase 1A) — never from
  plugin code. SPEC §11 includes a grep invariant that fails CI if a
  `Ezagent.Plugin.*` or `ezagent_plugin_*` module references
  `Ezagent.EventLog`.

  ## Ordering — `(inserted_at, id)` composite (codex r2 MED-2 closure)

  Stream functions order rows by `(inserted_at ASC, id ASC)`. The `id`
  tie-breaker resolves multiple events written in the same microsecond
  (the `:utc_datetime_usec` microsecond resolution is the practical
  floor here). Descending mode flips both axes: `(inserted_at DESC,
  id DESC)`.

  ## Phase 2 — payload encoding

  `payload` is JSON-encoded via `Jason.encode!/1` at insert time
  because `Repo.insert_all/2` against a string table name does NOT
  auto-encode `:map` columns (the same constraint `Ezagent.DLQ` and
  `Ezagent.Audit` work around). On read, `args` arrives as a string;
  `decode_payload/1` round-trips it through `Jason.decode!/1`.
  """

  import Ecto.Query

  alias EzagentCore.Repo

  @type aggregate_uri :: URI.t() | String.t()
  @type event_name :: atom() | String.t()
  @type event_id :: pos_integer()

  @type event_ctx :: %{
          optional(:caller) => URI.t() | String.t() | nil,
          optional(:workspace_uri) => URI.t() | String.t(),
          optional(:trace_id) => String.t() | nil,
          optional(:inserted_at) => DateTime.t()
        }

  @type event_row :: %{
          required(:event_id) => event_id(),
          required(:aggregate_uri) => String.t(),
          required(:event_name) => String.t(),
          required(:payload) => map(),
          required(:caller) => String.t() | nil,
          required(:workspace_uri) => String.t(),
          required(:trace_id) => String.t() | nil,
          required(:inserted_at) => DateTime.t()
        }

  @type stream_opt ::
          {:since, DateTime.t()}
          | {:limit, pos_integer()}
          | {:order, :asc | :desc}

  # ---------------------------------------------------------------------
  # append/4
  # ---------------------------------------------------------------------

  @doc """
  Append a single event row to the EventLog and return the assigned
  `event_id`.

  Synchronous — unlike `Ezagent.Audit.Writer`'s batch path, this one
  goes directly through `Repo.insert_all/3` with `returning: [:id]`
  so the caller (Router phase 2) can correlate the event id with the
  effect that produced it.

  ## Arguments

  - `aggregate_uri` — the Kind instance the event is about (becomes
    `target` in the row). Accepts a `URI.t` or canonical string.
  - `event_name` — the emit-effect's event type (becomes `action`).
    Accepts an atom (`:message_sent`) or string (`"message_sent"`);
    stored as string.
  - `payload` — arbitrary map describing the event. JSON-encoded into
    the `args` column.
  - `ctx` — fields not derivable from the event itself:
    - `:caller` — who triggered the emit (URI or string). May be `nil`.
    - `:workspace_uri` — REQUIRED. The workspace the event is scoped
      to. The `invocations.workspace_uri` column is `NOT NULL` (§9 PR-6).
    - `:trace_id` — optional trace correlation id.
    - `:inserted_at` — optional override; defaults to `DateTime.utc_now/0`.

  Returns `{:ok, event_id}` on success. Returns `{:error, reason}` if
  the SQL insert raises (caller decides whether to retry or escalate).
  """
  @spec append(aggregate_uri(), event_name(), map(), event_ctx()) ::
          {:ok, event_id()} | {:error, term()}
  def append(aggregate_uri, event_name, payload, ctx)
      when is_map(payload) and is_map(ctx) do
    workspace_uri =
      Map.get(ctx, :workspace_uri) ||
        raise ArgumentError,
              "Ezagent.EventLog.append/4: ctx must include :workspace_uri " <>
                "(invocations.workspace_uri is NOT NULL per Phase 9 PR-6). " <>
                "Got ctx=#{inspect(ctx)}"

    row = %{
      trace_id: Map.get(ctx, :trace_id),
      caller: uri_to_string_or_nil(Map.get(ctx, :caller)),
      target: uri_to_string!(aggregate_uri),
      action: event_name_to_string!(event_name),
      args: Jason.encode!(payload),
      result: nil,
      duration_us: 0,
      authz: "n/a",
      exception: nil,
      workspace_uri: uri_to_string!(workspace_uri),
      inserted_at: Map.get(ctx, :inserted_at, DateTime.utc_now())
    }

    try do
      {1, [%{id: event_id}]} =
        Repo.insert_all("invocations", [row], returning: [:id])

      {:ok, event_id}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------
  # stream_by_aggregate/2
  # ---------------------------------------------------------------------

  @doc """
  Stream events for a single aggregate (Kind instance), ordered by
  `(inserted_at, id)` composite.

  ## Options

  - `:since` — DateTime; rows strictly newer than this timestamp.
  - `:limit` — positive integer; cap on number of rows returned.
  - `:order` — `:asc` (default) | `:desc`. The composite tie-breaker
    flips with the primary axis.

  Returns a list of `event_row` maps (the `Stream.t()` typespec in the
  SPEC is aspirational — Phase 1 backs with `Repo.all/1` and returns a
  bounded list; switching to `Repo.stream/1` is a Phase 2 optimisation
  once large-aggregate replay is exercised).
  """
  @spec stream_by_aggregate(aggregate_uri(), [stream_opt()]) :: [event_row()]
  def stream_by_aggregate(aggregate_uri, opts \\ []) do
    target_str = uri_to_string!(aggregate_uri)

    base_query =
      from(i in "invocations",
        where: i.target == ^target_str,
        select: %{
          id: i.id,
          target: i.target,
          action: i.action,
          args: i.args,
          caller: i.caller,
          workspace_uri: i.workspace_uri,
          trace_id: i.trace_id,
          inserted_at: i.inserted_at
        }
      )

    base_query
    |> apply_since(opts)
    |> apply_order(opts)
    |> apply_limit(opts)
    |> Repo.all()
    |> Enum.map(&row_to_event/1)
  end

  # ---------------------------------------------------------------------
  # stream_by_workspace/2
  # ---------------------------------------------------------------------

  @doc """
  Stream events scoped to a workspace, ordered by `(inserted_at, id)`
  composite.

  Same options as `stream_by_aggregate/2`. Used by workspace-scoped
  audit views (admin LV's per-workspace audit pane) and by Phase 2
  EventSubscriber `{:workspace, uri}` subscriptions.
  """
  @spec stream_by_workspace(URI.t() | String.t(), [stream_opt()]) :: [event_row()]
  def stream_by_workspace(workspace_uri, opts \\ []) do
    ws_str = uri_to_string!(workspace_uri)

    base_query =
      from(i in "invocations",
        where: i.workspace_uri == ^ws_str,
        select: %{
          id: i.id,
          target: i.target,
          action: i.action,
          args: i.args,
          caller: i.caller,
          workspace_uri: i.workspace_uri,
          trace_id: i.trace_id,
          inserted_at: i.inserted_at
        }
      )

    base_query
    |> apply_since(opts)
    |> apply_order(opts)
    |> apply_limit(opts)
    |> Repo.all()
    |> Enum.map(&row_to_event/1)
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp apply_since(query, opts) do
    case Keyword.fetch(opts, :since) do
      {:ok, %DateTime{} = since} ->
        from(i in query, where: i.inserted_at > ^since)

      :error ->
        query
    end
  end

  defp apply_order(query, opts) do
    case Keyword.get(opts, :order, :asc) do
      :asc -> from(i in query, order_by: [asc: i.inserted_at, asc: i.id])
      :desc -> from(i in query, order_by: [desc: i.inserted_at, desc: i.id])
    end
  end

  defp apply_limit(query, opts) do
    case Keyword.fetch(opts, :limit) do
      {:ok, n} when is_integer(n) and n > 0 ->
        from(i in query, limit: ^n)

      :error ->
        query
    end
  end

  defp row_to_event(row) do
    %{
      event_id: row.id,
      aggregate_uri: row.target,
      event_name: row.action,
      payload: decode_payload(row.args),
      caller: row.caller,
      workspace_uri: row.workspace_uri,
      trace_id: row.trace_id,
      inserted_at: row.inserted_at
    }
  end

  # `args` is stored as TEXT (JSON-encoded). For rows written by the
  # legacy `Ezagent.Audit.Writer` path (which inserts nil for `args`
  # on most rows), preserve nil rather than synthesising `%{}`.
  defp decode_payload(nil), do: nil
  defp decode_payload(""), do: nil

  defp decode_payload(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, decoded} -> decoded
      {:error, _} -> s
    end
  end

  defp decode_payload(other), do: other

  defp uri_to_string!(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string!(s) when is_binary(s), do: s

  defp uri_to_string!(other) do
    raise ArgumentError,
          "Ezagent.EventLog: expected %URI{} or string, got #{inspect(other)}"
  end

  defp uri_to_string_or_nil(nil), do: nil
  defp uri_to_string_or_nil(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string_or_nil(s) when is_binary(s), do: s

  defp event_name_to_string!(a) when is_atom(a), do: Atom.to_string(a)
  defp event_name_to_string!(s) when is_binary(s), do: s

  defp event_name_to_string!(other) do
    raise ArgumentError,
          "Ezagent.EventLog: event_name must be atom or string, got #{inspect(other)}"
  end
end
