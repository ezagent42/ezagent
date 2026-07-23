defmodule Ezagent.Audit do
  @moduledoc """
  Telemetry handler that fans `[:ezagent, :invoke, :stop]` and
  `[:ezagent, :invoke, :error]` events out to **both**:

  1. `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:audit:stream",
     {:audit_event, event})` — for view fan-outs (LiveView `/admin`,
     future Feishu admin, CLI tail). This is the §5.7.6-legitimate
     broadcast (audience is undefined observers).
  2. `GenServer.cast(Ezagent.Audit.Writer, {:write, row})` — for the
     async Postgres write.

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
    [:ezagent, :session, :reply_dispatch_failed],
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
    [:ezagent, :session, :receive, :dropped]
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

    # Path 2: async write to Postgres via the batch writer.
    GenServer.cast(Ezagent.Audit.Writer, {:write, build_row(event, measurements, metadata)})
  end

  @doc "Topic for LV / view subscribers to subscribe to."
  def stream_topic, do: @audit_stream_topic

  # ---------------------------------------------------------------------
  # The PubSub message keeps the raw event shape for view rendering;
  # the Postgres row uses the column shape required by the migrations.

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
      # JSON-encode for the schemaless insert_all (string table name → no type casting; see Ezagent.DLQ).
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
  defp build_row([:ezagent, :session, :reply_dispatch_failed], _measurements, meta) do
    agent = Map.get(meta, :agent)
    target = "#{Map.get(meta, :target_session)}?action=session.send"

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
  #
  # r2 codex tightening (SPEC #324 rev 3): when `meta[:uri]` is missing
  # (e.g. `Ezagent.Audit.Writer` flush failure emits `%{component:
  # :audit_writer}` with no URI), use a `system://` synthetic identifier
  # so the strict `derive_workspace/2` allowlist accepts it AND the
  # workspace lands in `workspace://system` (admin's structural sink
  # for operational telemetry). The prior `snapshot://unknown` literal
  # was not in the allowlist and would have raised inside the telemetry
  # handler for the audit pipeline's own failure path — exactly when we
  # need the diagnostic event most.
  defp build_row([:ezagent, :persistence, phase], measurements, meta)
       when phase in [:restored, :written, :failed] do
    target = Map.get(meta, :uri) || synthetic_persistence_target(meta)

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
      # `derive_workspace` accepts the synthetic `system://` target via
      # the strict allowlist (system_scoped_uri?/1).
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
      # SPEC #324 rev 3 — cc-bridge:// is a synthetic identifier (not
      # in the 6-scheme allowlist); the event payload does not carry
      # the bridge's owning agent URI. cc-bridge events are admin-
      # instrumented operational telemetry, so landing them in
      # workspace://system (the admin workspace) is structurally
      # correct: a `system://`-shaped audit event for the admin tier.
      # Inlined literal — no global default function per Allen 2026-05-25.
      workspace_uri: system_workspace_uri_string(),
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
  defp build_row([:ezagent, :session, :receive, :dropped], _measurements, meta) do
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

  # r2 codex tightening: structured synthetic target for persistence-
  # telemetry rows that lack a `meta[:uri]`. The component name is the
  # path segment so operators can grep audit rows by source emitter
  # (e.g. `system://audit-writer/flush`).
  defp synthetic_persistence_target(meta) do
    component = Map.get(meta, :component) || :persistence
    component |> Ezagent.URI.system(:flush) |> URI.to_string()
  end

  defp uri_to_string_or_nil(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string_or_nil(s) when is_binary(s), do: s
  defp uri_to_string_or_nil(_), do: nil

  # Phase 9 PR-6 (SPEC v3 §7) + SPEC #324 rev 3 (Allen 2026-05-25) +
  # r1 codex tightening — derive the workspace_uri for an audit row.
  #
  # Rules:
  # 1. Caller's workspace if derivable structurally (entity / workspace /
  #    session URI).
  # 2. Target's workspace if derivable structurally.
  # 3. If ALL provided URIs are exactly `system://`-scheme (strict — no
  #    "anything not entity/workspace/session" wildcard), land in
  #    `workspace://system` (admin's workspace; structural sink for
  #    system-tier events — SPEC v3 §13.1).
  # 4. Otherwise RAISE. r1 codex caught: the prior `cross_cutting_or_nil?/1`
  #    predicate accepted nil, malformed input, AND any non-{entity,
  #    workspace, session} scheme as "cross-cutting", which silently
  #    routed unknown / future tenant-scoped schemes into the system
  #    workspace — the exact silent-default bug class Allen deleted.
  #
  # Synthetic operational identifiers (cc-bridge://) MUST NOT rely on
  # this fallback — those build_row clauses inline `"workspace://system"`
  # directly with a comment (see the `:cc_bridge, :event` clause above).
  defp derive_workspace(caller, target) do
    uris = Enum.reject([caller, target], &is_nil/1)

    derived =
      Enum.find_value(uris, fn uri ->
        case Ezagent.Persistence.workspace_uri_for(uri) do
          {:ok, ws} -> ws
          {:error, :no_workspace} -> nil
        end
      end)

    cond do
      not is_nil(derived) ->
        derived

      # Strict allowlist — every provided URI must be a system:// URI
      # for the system fallback to apply. Empty `uris` (both caller +
      # target nil) also hits this branch — a "no provided URIs" event
      # is a structural bug in the emitter (the telemetry handler MUST
      # know who/what triggered it), so the underlying assertion that
      # there is at least one URI is enforced by build_row.
      uris != [] and Enum.all?(uris, &system_scoped_uri?/1) ->
        system_workspace_uri_string()

      true ->
        raise ArgumentError,
              "Ezagent.Audit.derive_workspace/2: no workspace could be derived from " <>
                "caller=#{inspect(caller)}, target=#{inspect(target)}. Per SPEC #324 " <>
                "rev 3, audit emitters MUST pass entity / workspace / session URIs " <>
                "(which carry workspace structurally), or system-scheme URIs " <>
                "(admin-scope). Unknown / synthetic schemes must inline " <>
                "the workspace at the build_row clause — never rely on a fallback " <>
                "predicate, because that's the silent-default bug class Allen deleted " <>
                "on 2026-05-25."
    end
  end

  # r1 codex tightening: a URI is system-scoped if its scheme is EXACTLY
  # `system`. Synthetic / unknown / malformed URIs do NOT pass this gate —
  # those must be handled explicitly at the build_row level.
  defp system_scoped_uri?(uri) do
    parsed =
      case uri do
        %URI{} = u ->
          u

        s when is_binary(s) ->
          # SPEC 2026-05-27-uri-canonicalization §3.7 — Ezagent schemes via
          # canonical chokepoint; non-Ezagent strings produce `nil` so the
          # system-scoped predicate returns false (correct: unknown scheme
          # is not system-scoped).
          try do
            Ezagent.URI.new!(s)
          rescue
            ArgumentError -> nil
          end

        _ ->
          nil
      end

    case parsed do
      %URI{scheme: "system"} -> true
      _ -> false
    end
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

  # Phase 4 Item 4 — `Ezagent.Cmd.new/4` defaults `ctx.caller` to the atom
  # `:vm_internal` (the trusted in-VM caller marker; #154, renamed from the
  # overloaded `:system` — see `apps/ezagent_core/lib/ezagent/cmd.ex`). The
  # audit telemetry handler receives that atom verbatim via the `:invoke` /
  # `:authz` events. We canonicalize the atom at the boundary into a
  # `system://` URI string so it flows through the strict
  # `system_scoped_uri?/1` allowlist and lands the audit row in
  # `workspace://system` (admin tier) — the same treatment as any other
  # system-scoped caller. Without this clause the handler crashes
  # (no-function-clause), telemetry detaches the handler for the rest of the
  # node lifetime, and the audit log silently goes missing (see
  # scenario_30_plugin_greenfield_test.exs's pre-detach workaround).
  defp uri_to_str(:vm_internal),
    do: :anonymous |> Ezagent.URI.system_principal() |> URI.to_string()

  defp uri_to_str(a) when is_atom(a), do: a |> Ezagent.URI.system_principal() |> URI.to_string()
  defp stringify(nil), do: nil
  defp stringify(a) when is_atom(a), do: Atom.to_string(a)
  defp stringify(s) when is_binary(s), do: s

  defp system_workspace_uri_string, do: :system |> Ezagent.URI.workspace() |> URI.to_string()
end
