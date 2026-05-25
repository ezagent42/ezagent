defmodule Ezagent.Audit do
  @moduledoc """
  Telemetry handler that fans `[:ezagent, :invoke, :stop]` and
  `[:ezagent, :invoke, :error]` events out to **both**:

  1. `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:audit:stream",
     {:audit_event, event})` — for view fan-outs (LiveView `/admin`,
     future Feishu admin, CLI tail). This is the §5.7.6-legitimate
     broadcast (audience is undefined observers).
  2. `GenServer.cast(Ezagent.Audit.Writer, {:write, row})` — for the
     async SQLite write.

  The handler itself only does these two non-blocking ops, never
  touches the DB directly. That's enforced by invariant #6 (grep
  `Ezagent.Repo|Repo.insert|exqlite` in `audit.ex` must be empty).

  ## attach/0

  Called from `EzagentCore.Application.start/2` after the Writer is up.
  Idempotent — `:telemetry.attach/4` overwrites prior handlers of the
  same id.
  """

  @handler_id "esr-audit"
  @audit_stream_topic "esr:audit:stream"

  # Phase 3d hard flip (per P3-D6 + #B5):
  # - [:ezagent, :authz, :granted] / :denied REPLACE the Phase 1-2 :stub_grant
  #   marker. New audit rows carry "granted" / "denied" in the authz
  #   column; check_invariants #9 enforces :stub_grant atom no longer
  #   appears in code (only allowed in this audit.ex if we needed
  #   backward-compat decoding, which we don't — Phase 3d hard flip).
  @events [
    [:ezagent, :invoke, :stop],
    [:ezagent, :invoke, :error],
    [:ezagent, :authz, :granted],
    [:ezagent, :authz, :denied],
    # Phase 3d quality hotfix: chat reply dispatch fail visibility
    # (was silent before — real-claude e2e exposed wrong session_uri
    # disappearing into the void).
    [:ezagent, :chat, :reply_dispatch_failed],
    # Phase 4-completion Spec 04: per-Kind state persistence events.
    [:ezagent, :persistence, :restored],
    [:ezagent, :persistence, :written],
    [:ezagent, :persistence, :failed],
    # Phase 4-plus follow-up (2026-05-17): CC-side hook reports.
    # Audit table records the event so operators have a queryable
    # history even after the in-memory LV panel rolls over.
    [:ezagent, :cc_bridge, :event],
    # Notifier/log audit 2026-05-24 MED — capture every Notifications
    # emission for the audit trail. Lets operators see "who got
    # notified what when" alongside the audit-authz events.
    [:ezagent, :notification, :emit],
    # Notifier/log audit 2026-05-24 MED — chat-receive drops were
    # logged to Logger but never made the audit table. Now they do.
    [:ezagent, :chat, :receive, :dropped]
  ]

  @doc """
  Attach telemetry handlers. Idempotent — already-attached returns `:ok`.
  """
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    audit_event = %{
      event: event,
      measurements: measurements,
      metadata: serialise_metadata(metadata),
      at: DateTime.utc_now()
    }

    # Path 1: PubSub broadcast for LV / future view fan-outs (§5.7.6
    # legitimate broadcast — audience is undefined observers).
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, @audit_stream_topic, {:audit_event, audit_event})

    # Path 2: async write to SQLite via the batch writer.
    GenServer.cast(Ezagent.Audit.Writer, {:write, build_row(event, measurements, metadata)})
  end

  @doc "Topic for LV / view subscribers to subscribe to."
  def stream_topic, do: @audit_stream_topic

  # ---------------------------------------------------------------------
  # The PubSub message keeps the raw event shape for view rendering;
  # the SQLite row uses the column shape required by the migrations.

  defp build_row([:ezagent, :invoke, :stop], %{duration_us: us}, meta) do
    caller = uri_to_str(Map.get(meta, :caller))
    target = uri_to_str(Map.get(meta, :target))

    %{
      trace_id: nil,
      caller: caller,
      target: target,
      action: stringify(Map.get(meta, :action)),
      args: nil,
      result: nil,
      duration_us: us,
      # Phase 3d: authz column from real cap check. :granted event has
      # already fired before this :invoke :stop, so we record "granted"
      # for success. The :denied path never reaches :invoke :stop
      # because dispatch short-circuits with {:error, :unauthorized}.
      authz: "granted",
      exception: nil,
      # Phase 9 PR-6 (SPEC v3 §7) — audit row is scoped to the caller's
      # workspace (the "tenant on whose behalf the action ran") with
      # fallback to target then default.
      workspace_uri: derive_workspace(caller, target),
      inserted_at: DateTime.utc_now()
    }
  end

  defp build_row([:ezagent, :invoke, :error], %{duration_us: us}, meta) do
    reason = Map.get(meta, :reason)
    caller = uri_to_str(Map.get(meta, :caller))
    target = uri_to_str(Map.get(meta, :target))

    # Distinguish authz denied from other errors so the audit row's
    # authz column is meaningful for operators debugging permissions.
    # Phase 9 PR-4 (SPEC v3 §5): cross-workspace denial is a separate
    # bucket — operators debugging "my dispatch failed" need to see
    # whether it was a missing cap (`denied`) or a workspace isolation
    # violation (`cross_workspace_denied`).
    authz =
      case reason do
        :unauthorized -> "denied"
        :cross_workspace_denied -> "cross_workspace_denied"
        _ -> "n/a"
      end

    %{
      trace_id: nil,
      caller: caller,
      target: target,
      action: nil,
      args: nil,
      result: nil,
      duration_us: us,
      authz: authz,
      # JSON-encode for ecto_sqlite3 schemaless insert_all (see Ezagent.DLQ).
      exception: Jason.encode!(%{reason: inspect(reason)}),
      workspace_uri: derive_workspace(caller, target),
      inserted_at: DateTime.utc_now()
    }
  end

  # Phase 3d: :authz events also persist a row so the audit log shows
  # the granted/denied decision separately from invoke success/error.
  defp build_row([:ezagent, :authz, decision], _measurements, meta) do
    caller = uri_to_str(Map.get(meta, :caller))
    target = uri_to_str(Map.get(meta, :target))

    %{
      trace_id: nil,
      caller: caller,
      target: target,
      action: stringify(Map.get(meta, :action)),
      args: nil,
      result: nil,
      duration_us: 0,
      authz: Atom.to_string(decision),
      exception: nil,
      workspace_uri: derive_workspace(caller, target),
      inserted_at: DateTime.utc_now()
    }
  end

  # Phase 3d quality hotfix: chat reply dispatch failure (agent's chat/send
  # targeting a non-existent session). Persisted so admin can see why a
  # claude reply silently disappeared.
  defp build_row([:ezagent, :chat, :reply_dispatch_failed], _measurements, meta) do
    agent = Map.get(meta, :agent)
    target = "#{Map.get(meta, :target_session)}?action=chat.send"

    %{
      trace_id: nil,
      caller: agent,
      target: target,
      action: "send",
      args: nil,
      result: nil,
      duration_us: 0,
      authz: "n/a",
      exception:
        Jason.encode!(%{
          reason: inspect(Map.get(meta, :reason)),
          message_id: Map.get(meta, :message_id)
        }),
      workspace_uri: derive_workspace(agent, target),
      inserted_at: DateTime.utc_now()
    }
  end

  # Phase 4-completion Spec 04: persistence telemetry as audit rows so
  # operators see snapshot lifecycle in the same /admin Audit Log stream.
  # Defensive target fallback: build_row must never produce NULL target
  # (NOT NULL constraint on invocations.target).
  defp build_row([:ezagent, :persistence, phase], measurements, meta)
       when phase in [:restored, :written, :failed] do
    target = Map.get(meta, :uri) || "snapshot://unknown"

    %{
      trace_id: nil,
      caller: nil,
      target: target,
      action: "snapshot.#{phase}",
      args: nil,
      result:
        Jason.encode!(%{
          slices: Map.get(measurements, :slices),
          bytes: Map.get(measurements, :bytes),
          kind_type: Map.get(meta, :kind_type),
          version: Map.get(meta, :version)
        }),
      duration_us: 0,
      authz: "n/a",
      exception:
        if phase == :failed do
          Jason.encode!(%{reason: Map.get(meta, :reason)})
        else
          nil
        end,
      workspace_uri: derive_workspace(nil, target),
      inserted_at: DateTime.utc_now()
    }
  end

  # Phase 4-plus follow-up: CC bridge hook reports persist as audit
  # rows so an operator can grep history beyond the LV in-memory buffer.
  defp build_row([:ezagent, :cc_bridge, :event], _measurements, meta) do
    bridge_id = Map.get(meta, :bridge_id, "unknown")

    %{
      trace_id: nil,
      caller: "cc-bridge://#{bridge_id}",
      target: "cc-bridge://#{bridge_id}/event",
      action: "cc.#{Map.get(meta, :type, "event")}",
      args: nil,
      result: nil,
      duration_us: 0,
      authz: Map.get(meta, :level, "info"),
      exception: Map.get(meta, :text),
      # cc-bridge:// is a synthetic identifier — workspace_uri is
      # derived from the bridge's owning agent via a future indirection
      # (out of scope for PR-6); for now we default to keep the audit
      # log writable.
      workspace_uri: Ezagent.Persistence.default_workspace_uri(),
      inserted_at: DateTime.utc_now()
    }
  end

  # Notifier/log audit 2026-05-24 MED — emitted by `Ezagent.Notifications.notify/3`.
  defp build_row([:ezagent, :notification, :emit], _measurements, meta) do
    user_uri = Map.get(meta, :user_uri)
    caller = Map.get(meta, :caller)
    # Notification contract uses `:type`; fall back to legacy `:kind`
    # for any stragglers during transition.
    type = Map.get(meta, :type) || Map.get(meta, :kind)

    %{
      trace_id: nil,
      caller: uri_to_string_or_nil(caller),
      target: uri_to_string_or_nil(user_uri),
      action: "notification.emit#{if type, do: ":#{type}", else: ""}",
      args: nil,
      result: nil,
      duration_us: 0,
      authz: "info",
      exception: nil,
      workspace_uri: derive_workspace(caller, user_uri),
      inserted_at: DateTime.utc_now()
    }
  end

  # Notifier/log audit 2026-05-24 MED — emitted by `Chat.invoke(:receive, ...)`
  # when the recipient has no BridgeRegistry binding (the chat target
  # was reached but no transport could push it). Pre-fix: Logger only,
  # never made the audit table.
  defp build_row([:ezagent, :chat, :receive, :dropped], _measurements, meta) do
    %{
      trace_id: nil,
      caller: uri_to_string_or_nil(Map.get(meta, :sender)),
      target: uri_to_string_or_nil(Map.get(meta, :recipient)),
      action: "chat.receive.dropped",
      args: nil,
      result: nil,
      duration_us: 0,
      authz: "warn",
      exception: Map.get(meta, :reason, "no_binding"),
      workspace_uri: derive_workspace(Map.get(meta, :sender), Map.get(meta, :recipient)),
      inserted_at: DateTime.utc_now()
    }
  end

  defp uri_to_string_or_nil(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string_or_nil(s) when is_binary(s), do: s
  defp uri_to_string_or_nil(_), do: nil

  # Phase 9 PR-6 (SPEC v3 §7) — derive the workspace_uri for an audit
  # row given the caller and target URI strings. Priority:
  # 1. Caller's workspace (the principal on whose behalf the action ran)
  # 2. Target's workspace
  # 3. Default workspace (audit log must never have NULL workspace_uri)
  #
  # `caller` may be nil (system events have no human principal); `target`
  # is always set per the build_row contract.
  defp derive_workspace(caller, target) do
    [caller, target]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn uri ->
      case Ezagent.Persistence.workspace_uri_for(uri) do
        {:ok, ws} -> ws
        {:error, :no_workspace} -> nil
      end
    end)
    |> case do
      nil -> Ezagent.Persistence.default_workspace_uri()
      ws -> ws
    end
  rescue
    # Any failure deriving (malformed URI, registry miss, etc.) →
    # default workspace. The audit log is the catch-all observability
    # surface — it must never be the cause of a write failure.
    _ -> Ezagent.Persistence.default_workspace_uri()
  end

  defp serialise_metadata(meta) do
    meta
    |> Enum.map(fn
      {k, %URI{} = u} -> {k, URI.to_string(u)}
      {k, v} when is_atom(v) -> {k, v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
  defp uri_to_str(nil), do: nil
  defp stringify(nil), do: nil
  defp stringify(a) when is_atom(a), do: Atom.to_string(a)
  defp stringify(s) when is_binary(s), do: s
end
