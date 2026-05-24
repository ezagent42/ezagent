defmodule Ezagent.ExternalMirror.BootReconciler do
  @moduledoc """
  `Ezagent.ExternalMirror.BootReconciler` — application-boot
  reconciliation of persisted bindings.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §3.1 trigger (2) — closes HIGH-3 (persisted bindings have no
  worker after rehydrate).

  ## What it does

  On application boot, walks every row in `external_mirror_bindings`
  and idempotently:

  1. Ensures the Session Kind exists via `SpawnRegistry.spawn/1`
     (the Session's `init_slice/1` rehydration will rebuild the
     `:external_mirror` slice + `post_init/2` schedules a
     `handle_continue(:reconcile_external_mirror_workers, ...)`
     that spawns each Worker via `Kind.spawn/2`).
  2. Idempotently spawns the Worker directly via
     `Kind.spawn(ExternalMirrorWorker, ...)`. This is belt-and-
     suspenders against the case where Session-init reconciliation
     fired but the Worker spawn race lost (a different node beat
     us — V1 single-node so this is a no-op safety net).

  Per **P16**, both `Kind.spawn/2`s are idempotent (Session via
  `SpawnRegistry`'s own check; Worker via the two-tier RootSupervisor
  + Registry-keyed `:via` name). Already-alive Kinds return
  `{:error, {:already_started, _pid}}` which we treat as success.

  ## One-shot — exits cleanly after a single pass

  V1 single-node — no continuous reconciliation, no shard
  recomputation. The GenServer runs ONE pass in `handle_continue/2`,
  then `{:stop, :normal, _state}` exits the process. The
  Application supervisor's `:transient` restart strategy (the
  default for the `start_link/1` shape) means a `:normal` exit is
  NOT restarted — the supervisor moves on.

  ## Boot ordering

  Listed in `EzagentDomainExternalMirror.Application.children/0`
  AFTER `WorkerRegistry` + `RootSupervisor` + `TargetCheckTaskSup` so
  the supervisors it uses (`RootSupervisor` for Worker spawns) are
  already alive when `handle_continue/2` runs. The session-side
  `SpawnRegistry` lives in `:ezagent_core` and is started by chat's
  Application; reconciliation tolerates SpawnRegistry not being
  populated yet (best-effort — logs + continues).

  ## DB tolerance

  If the `external_mirror_bindings` table is unreachable at boot
  (Ecto Sandbox not checked out in test env, repo not started,
  fresh DB without migration), the GenServer logs a warning and
  exits without touching any Kind. Each Session Kind's own
  `init_slice/1` is the primary rehydration path; BootReconciler is
  the multi-node safety net.
  """

  use GenServer

  require Logger

  alias Ezagent.ExternalMirror.BindingRow

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Boot ordering: defer the actual reconciliation to handle_continue
    # so init/1 returns quickly + the rest of the supervision tree
    # finishes starting.
    {:ok, %{}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    case safe_list_all_rows() do
      {:ok, rows} ->
        results =
          Enum.reduce(rows, %{ok: 0, session_failed: 0, worker_failed: 0}, fn row, acc ->
            reconcile_row(row, acc)
          end)

        if results.ok > 0 or results.session_failed > 0 or results.worker_failed > 0 do
          Logger.info(
            "ExternalMirror.BootReconciler: pass complete — " <>
              "reconciled=#{results.ok} session_failed=#{results.session_failed} " <>
              "worker_failed=#{results.worker_failed}"
          )
        end

      {:error, reason} ->
        Logger.warning(
          "ExternalMirror.BootReconciler: skipped (DB unreachable / table missing): " <>
            inspect(reason)
        )
    end

    {:stop, :normal, state}
  end

  # ----- internals --------------------------------------------------------

  defp safe_list_all_rows do
    {:ok, BindingRow.list_all()}
  rescue
    err -> {:error, err}
  end

  defp reconcile_row(%BindingRow{} = row, acc) do
    session_uri = URI.parse(row.session_uri)

    session_outcome = ensure_session_alive(session_uri)
    worker_outcome = ensure_worker_alive(row, session_uri)

    cond do
      session_outcome == :ok and worker_outcome == :ok ->
        %{acc | ok: acc.ok + 1}

      session_outcome != :ok ->
        Logger.warning(
          "ExternalMirror.BootReconciler: session spawn failed for #{row.session_uri}: " <>
            inspect(session_outcome)
        )

        %{acc | session_failed: acc.session_failed + 1}

      true ->
        Logger.warning(
          "ExternalMirror.BootReconciler: worker spawn failed for " <>
            "#{row.session_uri}/#{row.adapter_id}/#{row.target_id}: " <>
            inspect(worker_outcome)
        )

        %{acc | worker_failed: acc.worker_failed + 1}
    end
  end

  defp ensure_session_alive(%URI{} = session_uri) do
    # SpawnRegistry is the public idempotent entry for any URI scheme;
    # the session:// dispatcher (registered by EzagentDomainChat) calls
    # Kind.spawn(Session, ...) under the hood. We tolerate
    # SpawnRegistry not being populated yet (chat application not
    # started — would happen if external_mirror boots before chat in
    # the umbrella; in practice the dep edge keeps chat alive first).
    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  rescue
    err -> {:error, err}
  end

  defp ensure_worker_alive(%BindingRow{} = row, %URI{} = session_uri) do
    # Belt-and-suspenders: skip if the adapter isn't registered. The
    # Worker's post-init `handle_continue` would raise KeyError on
    # `AdapterRegistry.lookup!/1` (per SPEC §5.2 structural-error
    # rule) — which would crash the Worker, exhaust the
    # PerBindingSupervisor's 3/30s budget, then trip the
    # RootSupervisor's 100/60s budget if many bindings reference
    # missing adapters. The result was a cascade that could bring
    # down the entire ExternalMirror Application during test runs
    # where rows from prior runs lingered in the DB but their
    # adapters weren't yet plugin-booted.
    #
    # The proper fix: skip rows for unregistered adapters with a
    # warning. The Worker WILL be reconciled later when the
    # plugin's adapter eventually registers (e.g. on next boot when
    # plugin boot ordering settles).
    case Ezagent.ExternalMirror.AdapterRegistry.lookup(row.adapter_id) do
      {:ok, _adapter_module} ->
        do_spawn_worker(row, session_uri)

      :error ->
        Logger.debug(
          "ExternalMirror.BootReconciler: skipping row for unregistered adapter " <>
            "#{inspect(row.adapter_id)} (#{row.session_uri}/#{row.target_id}) — " <>
            "adapter not in registry yet"
        )

        :ok
    end
  rescue
    err -> {:error, err}
  end

  defp do_spawn_worker(%BindingRow{} = row, %URI{} = session_uri) do
    worker_uri =
      Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for(
        session_uri,
        row.adapter_id,
        row.target_id
      )

    params = %{
      uri: worker_uri,
      session_uri: session_uri,
      adapter_id: row.adapter_id,
      target_id: row.target_id,
      opts: decode_opts(row.opts_json)
    }

    case Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  rescue
    err -> {:error, err}
  end

  defp decode_opts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_opts(_), do: %{}
end
