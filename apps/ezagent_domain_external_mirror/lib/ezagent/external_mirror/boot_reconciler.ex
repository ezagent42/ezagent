defmodule Ezagent.ExternalMirror.BootReconciler do
  @moduledoc """
  `Ezagent.ExternalMirror.BootReconciler` — application-boot
  Session-rehydration safety net.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §3.1 trigger (2).

  ## What it does (post r3 — Session-only)

  On application boot, walks every row in `external_mirror_bindings`
  and idempotently ensures the Session Kind exists via
  `SpawnRegistry.spawn/1` (the Session's `init_slice/1` rehydration
  rebuilds the `:external_mirror` slice + `post_init/2` schedules a
  `handle_continue(:reconcile_external_mirror_workers, ...)` that
  spawns each Worker via `Kind.spawn/2`).

  Worker spawn no longer happens here — codex r2 HIGH-1 moved
  per-adapter Worker reconciliation into
  `Ezagent.ExternalMirror.AdapterInstall.install/1`, which is
  triggered the moment a plugin adapter registers (event-driven,
  not poll-driven). BootReconciler keeps the Session-existence
  safety net because a session that has bindings but no other
  trigger to spawn (no chat traffic, no LV subscription) would
  otherwise stay un-rehydrated until first use.

  Per **P16**, `SpawnRegistry.spawn/1` is idempotent — already-
  alive Session Kinds return `{:error, {:already_started, _pid}}`
  which we treat as success.

  ## One-shot — exits cleanly after a single pass

  V1 single-node — no continuous reconciliation, no shard
  recomputation. The GenServer runs ONE pass in `handle_continue/2`,
  then `{:stop, :normal, _state}` exits the process. The
  Application supervisor's `:transient` restart strategy (the
  default for the `start_link/1` shape) means a `:normal` exit is
  NOT restarted — the supervisor moves on.

  ## Boot ordering

  Listed in `EzagentDomainExternalMirror.Application.children/0`
  AFTER `WorkerRegistry` + `RootSupervisor` + `TargetCheckTaskSup`.
  The session-side `SpawnRegistry` lives in `:ezagent_core` and is
  started by chat's Application; reconciliation tolerates the
  session:// scheme handler not being registered yet (best-effort
  — logs + continues).

  ## DB tolerance

  If the `external_mirror_bindings` table is unreachable at boot
  (Ecto Sandbox not checked out in test env, repo not started,
  fresh DB without migration), the GenServer logs a warning and
  exits without touching any Kind. Each Session Kind's own
  `init_slice/1` is the primary rehydration path; this is the
  multi-node / cold-start safety net.
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
        # Deduplicate by session_uri — Session Kind spawn is per-
        # session, not per-binding, so 10 bindings on one session
        # only need one spawn attempt.
        session_uris =
          rows
          |> Enum.map(& &1.session_uri)
          |> Enum.uniq()
          |> Enum.map(&URI.parse/1)

        {ok_count, fail_count} =
          Enum.reduce(session_uris, {0, 0}, fn session_uri, {ok_acc, fail_acc} ->
            case ensure_session_alive(session_uri) do
              :ok ->
                {ok_acc + 1, fail_acc}

              other ->
                Logger.warning(
                  "ExternalMirror.BootReconciler: session spawn failed for " <>
                    "#{URI.to_string(session_uri)}: #{inspect(other)}"
                )

                {ok_acc, fail_acc + 1}
            end
          end)

        if ok_count > 0 or fail_count > 0 do
          Logger.info(
            "ExternalMirror.BootReconciler: pass complete — " <>
              "sessions_reconciled=#{ok_count} sessions_failed=#{fail_count}"
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
end
