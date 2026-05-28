defmodule Ezagent.ExternalMirror.BootReconciler do
  @moduledoc """
  `Ezagent.ExternalMirror.BootReconciler` — application-boot
  Session-rehydration safety net.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §3.1 trigger (2).

  ## What it does (post r3 — Session-only; r5 — retry loop)

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

  ## codex r4 HIGH-1 fix (2026-05-25) — bounded retry loop

  Pre-fix, the reconciler ran ONE pass in `handle_continue/2` then
  exited `:transient` `:normal`. If the chat application's
  `session://` SpawnRegistry handler hadn't registered YET (boot
  ordering: chat depends on external_mirror, so chat starts AFTER —
  the reconciler can race chat's `register_session_scheme/0` call),
  `SpawnRegistry.spawn/1` returned `{:error, {:no_spawn_fn,
  "session"}}` and the reconciler silently exited. Persisted
  bindings stayed un-reconciled until the next service restart that
  happened to win the race.

  Post-fix, the reconciler retries every #{2_000}ms for up to 30
  attempts (~60s total). Each pass tries to reconcile any sessions
  that previously failed. Failure modes:

  - `{:error, {:no_spawn_fn, "session"}}` → handler not yet
    registered, retry next tick.
  - `{:error, _other}` → log warning, drop from retry set (this
    URI is permanently broken in this boot — admin tooling can
    handle it; we don't want a single bad row to block the rest).
  - `:ok` / `{:already_started, _}` → success, drop from retry set.

  When the retry set drains to empty OR 30 attempts are exhausted
  (whichever first), the reconciler logs the final state and exits
  cleanly (`:normal` — `:transient` restart strategy means no
  respawn loop).

  ## Boot ordering

  Listed in `EzagentDomainExternalMirror.Application.children/0`
  AFTER `WorkerRegistry` + `RootSupervisor` + `TargetCheckTaskSup`.
  The session-side `SpawnRegistry` lives in `:ezagent_core` and is
  started by chat's Application; the retry loop tolerates the
  session:// scheme handler not being registered yet — retries
  until either the handler appears OR the retry budget is exhausted.

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

  # codex r4 HIGH-1: retry window. 30 attempts × 2_000 ms = 60s total.
  @retry_interval_ms 2_000
  @max_attempts 30

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Test helper — read tunables so a test can speed up the loop.
  @doc false
  def retry_interval_ms,
    do:
      Application.get_env(
        :ezagent_domain_external_mirror,
        :boot_reconciler_retry_interval_ms,
        @retry_interval_ms
      )

  @doc false
  def max_attempts,
    do:
      Application.get_env(
        :ezagent_domain_external_mirror,
        :boot_reconciler_max_attempts,
        @max_attempts
      )

  @impl true
  def init(_opts) do
    # Boot ordering: defer the actual reconciliation to handle_continue
    # so init/1 returns quickly + the rest of the supervision tree
    # finishes starting.
    {:ok, %{attempts: 0, pending: nil}, {:continue, :load_pending}}
  end

  @impl true
  def handle_continue(:load_pending, state) do
    case safe_list_all_rows() do
      {:ok, rows} ->
        # Deduplicate by session_uri — Session Kind spawn is per-
        # session, not per-binding, so 10 bindings on one session
        # only need one spawn attempt.
        session_uris =
          rows
          |> Enum.map(& &1.session_uri)
          |> Enum.uniq()
          |> Enum.map(&Ezagent.URI.parse!/1)
          |> MapSet.new()

        if MapSet.size(session_uris) == 0 do
          # Nothing to do — exit cleanly.
          {:stop, :normal, state}
        else
          # Kick off the retry loop immediately.
          send(self(), :reconcile_pass)
          {:noreply, %{state | pending: session_uris}}
        end

      {:error, reason} ->
        Logger.warning(
          "ExternalMirror.BootReconciler: skipped (DB unreachable / table missing): " <>
            inspect(reason)
        )

        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:reconcile_pass, %{attempts: attempts, pending: pending} = state)
      when is_struct(pending, MapSet) do
    attempts = attempts + 1

    {ok_set, retry_set, fail_set} =
      Enum.reduce(pending, {MapSet.new(), MapSet.new(), MapSet.new()}, fn session_uri,
                                                                          {ok_acc, retry_acc,
                                                                           fail_acc} ->
        case ensure_session_alive(session_uri) do
          :ok ->
            {MapSet.put(ok_acc, session_uri), retry_acc, fail_acc}

          {:retry, _reason} ->
            {ok_acc, MapSet.put(retry_acc, session_uri), fail_acc}

          {:fail, _reason} ->
            {ok_acc, retry_acc, MapSet.put(fail_acc, session_uri)}
        end
      end)

    if MapSet.size(fail_set) > 0 do
      Enum.each(fail_set, fn uri ->
        Logger.warning(
          "ExternalMirror.BootReconciler: session spawn permanently failed for " <>
            URI.to_string(uri)
        )
      end)
    end

    cond do
      MapSet.size(retry_set) == 0 ->
        # All sessions either reconciled or permanently failed —
        # done. Log the final tally.
        Logger.info(
          "ExternalMirror.BootReconciler: complete after #{attempts} attempt(s) — " <>
            "sessions_reconciled=#{MapSet.size(ok_set)} " <>
            "sessions_permanently_failed=#{MapSet.size(fail_set)}"
        )

        {:stop, :normal, state}

      attempts >= max_attempts() ->
        # Budget exhausted — log + give up. Operators can re-trigger
        # by restarting the external_mirror app.
        Logger.error(
          "ExternalMirror.BootReconciler: retry budget exhausted (#{max_attempts()} attempts × " <>
            "#{retry_interval_ms()}ms). " <>
            "sessions_reconciled=#{MapSet.size(ok_set)} " <>
            "sessions_still_pending=#{MapSet.size(retry_set)} " <>
            "sessions_permanently_failed=#{MapSet.size(fail_set)}. " <>
            "Pending: #{inspect(Enum.map(retry_set, &URI.to_string/1))}"
        )

        {:stop, :normal, state}

      true ->
        # Schedule next pass over the still-pending set.
        Process.send_after(self(), :reconcile_pass, retry_interval_ms())
        {:noreply, %{state | attempts: attempts, pending: retry_set}}
    end
  end

  # ----- internals --------------------------------------------------------

  defp safe_list_all_rows do
    {:ok, BindingRow.list_all()}
  rescue
    err -> {:error, err}
  end

  # Returns {:ok | {:retry, reason} | {:fail, reason}}.
  # - `:ok` — session is alive (fresh spawn or already_started)
  # - `{:retry, reason}` — session://-scheme handler not yet
  #   registered (chat hasn't booted past register_session_scheme).
  #   Try again next pass.
  # - `{:fail, reason}` — permanent failure (DB error, malformed
  #   URI, etc.) — don't retry.
  defp ensure_session_alive(%URI{} = session_uri) do
    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # codex r4 HIGH-1: scheme handler not registered yet — chat
      # hasn't run register_session_scheme/0. Retry next tick.
      {:error, {:no_spawn_fn, _scheme}} = reason ->
        {:retry, reason}

      other ->
        {:fail, other}
    end
  rescue
    err -> {:fail, err}
  end
end
