defmodule Ezagent.ExternalMirror.BootReconcilerTest do
  @moduledoc """
  Regression tests for codex r4 HIGH-1: BootReconciler must NOT
  silently exit when the session://-scheme SpawnRegistry handler
  isn't yet registered.

  Pre-fix: BootReconciler ran one pass via `handle_continue`; if
  the chat application hadn't yet registered the session:// scheme
  handler, `SpawnRegistry.spawn/1` returned
  `{:error, {:no_spawn_fn, "session"}}` and the reconciler exited
  `:normal` (under `restart: :transient` → no respawn). Persisted
  bindings stayed un-reconciled.

  Post-fix: BootReconciler retries every N ms (test-tunable) for up
  to M attempts. When the handler eventually registers, the next
  pass succeeds and the reconciler exits cleanly.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{BindingRow, BootReconciler}

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")
  @session_scheme "session"

  setup do
    # Speed up the retry loop for tests — 50ms tick, 10 attempts cap.
    orig_interval =
      Application.get_env(:ezagent_domain_external_mirror, :boot_reconciler_retry_interval_ms)

    orig_max =
      Application.get_env(:ezagent_domain_external_mirror, :boot_reconciler_max_attempts)

    Application.put_env(:ezagent_domain_external_mirror, :boot_reconciler_retry_interval_ms, 50)
    Application.put_env(:ezagent_domain_external_mirror, :boot_reconciler_max_attempts, 10)

    on_exit(fn ->
      restore_env(:boot_reconciler_retry_interval_ms, orig_interval)
      restore_env(:boot_reconciler_max_attempts, orig_max)
    end)

    :ok
  end

  describe "codex r4 HIGH-1 — retry loop until session://-scheme handler appears" do
    test "BootReconciler retries when SpawnRegistry has no session://-scheme handler, then succeeds when registered" do
      # Insert a binding row pointing at a fresh session URI.
      session_uri = fresh_session_uri("boot-recon-r5-1")
      :ok = insert_binding_row(session_uri, "mock_publish", "tgt-boot-recon-1")

      # Stash + remove the session-scheme handler (simulates chat
      # not yet booted past `register_session_scheme/0`). We rely on
      # the underlying ETS table `:ezagent_spawn_registry` since
      # `SpawnRegistry` has no public unregister API.
      original_handler = stash_session_handler!()

      try do
        # Start a fresh BootReconciler under a NON-named pid so we
        # don't clash with the app's already-running one.
        {:ok, pid} =
          GenServer.start_link(BootReconciler, [],
            name: :"boot_recon_test_#{System.unique_integer([:positive])}"
          )

        # The reconciler should NOT have exited immediately — it
        # should be retrying because session:// has no handler.
        Process.sleep(120)
        assert Process.alive?(pid), "BootReconciler exited before retry — HIGH-1 regression"

        # Now re-register the handler — next retry pass should succeed.
        restore_session_handler!(original_handler)

        # Wait for the reconciler to exit cleanly (it `:stop`s
        # `:normal` once all sessions are reconciled).
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      after
        # Restore the handler unconditionally.
        restore_session_handler!(original_handler)
      end
    end

    test "BootReconciler gives up after max_attempts when session://-scheme handler never appears" do
      session_uri = fresh_session_uri("boot-recon-r5-2")
      :ok = insert_binding_row(session_uri, "mock_publish", "tgt-boot-recon-2")

      original_handler = stash_session_handler!()

      try do
        # Lower max_attempts to 2 so the test finishes in <200ms.
        Application.put_env(:ezagent_domain_external_mirror, :boot_reconciler_max_attempts, 2)

        {:ok, pid} =
          GenServer.start_link(BootReconciler, [],
            name: :"boot_recon_test_#{System.unique_integer([:positive])}"
          )

        # Should exhaust budget + exit `:normal` (logs error but
        # doesn't crash — :transient strategy means a `:normal` exit
        # leaves the application supervision tree alive).
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      after
        restore_session_handler!(original_handler)
      end
    end
  end

  # ----- helpers -----------------------------------------------------------

  defp fresh_session_uri(prefix) do
    Ezagent.URI.new!("session://team-alpha/default/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp insert_binding_row(%URI{} = session_uri, adapter_id, target_id) do
    attrs = %{
      id: BindingRow.row_id(session_uri, adapter_id, target_id),
      session_uri: URI.to_string(session_uri),
      adapter_id: adapter_id,
      target_id: target_id,
      opts_json: "{}",
      bound_by: "entity://team-alpha/user/boot-recon-test",
      bound_at: DateTime.utc_now(),
      workspace_uri: URI.to_string(@workspace_uri)
    }

    case BindingRow.insert(attrs) do
      {:ok, _} -> :ok
      # Pre-existing row from another test is also fine (DataCase
      # rolls back per-test, but if anything leaks we treat as ok).
      {:error, _} -> :ok
    end
  end

  # SpawnRegistry has no public unregister/2; reach into the ETS
  # table directly. We restore in `after` to avoid breaking other
  # tests that depend on the session:// handler.
  defp stash_session_handler! do
    table = :ezagent_spawn_registry

    case :ets.lookup(table, @session_scheme) do
      [{@session_scheme, fun}] ->
        :ets.delete(table, @session_scheme)
        fun

      [] ->
        nil
    end
  end

  defp restore_session_handler!(nil), do: :ok

  defp restore_session_handler!(fun) when is_function(fun, 1) do
    :ets.insert(:ezagent_spawn_registry, {@session_scheme, fun})
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:ezagent_domain_external_mirror, key)
  defp restore_env(key, val), do: Application.put_env(:ezagent_domain_external_mirror, key, val)
end
