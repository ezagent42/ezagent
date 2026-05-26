defmodule EzagentPluginLiveview.AdminLiveRehydrateFlashTest do
  @moduledoc """
  codex PR #408 review MED-1 — `AdminLive.ensure_main_session/2`'s
  rehydrate path threads the orchestrator-status meta into the admin
  flash banner instead of log-only. Pre-fix the meta tuple was
  `log_orchestrator_status_on_rehydrate`'d (debug log only) and never
  surfaced to the operator — `:pending` / `:failed` orchestrator-spawn
  results on rehydrate were invisible.

  These tests exercise the meta-translation helper directly. The full
  rehydrate flow runs at LV mount/3 with `@main_session_uri` not yet
  alive — driving that scenario through a real LiveView test would
  require deregistering the boot-seeded session, which is fragile. The
  meta translation is a pure function over the meta map; this unit
  exercise pins the 3 branches (`:ready` / `:pending` / `:failed`).
  """

  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.AdminLive

  # Build a minimal Phoenix.LiveView.Socket so the LV module's
  # `assign/3` call inside `assign_rehydrate_flash/2` lands cleanly.
  defp fresh_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash_error: nil}
    }
  end

  describe ":ready status — no flash change" do
    test "ready meta leaves socket.flash_error untouched" do
      socket = fresh_socket()

      meta = %{
        orchestrator_uri: URI.new!("entity://agent/system/cc_orchestrator-main"),
        orchestrator_status: :ready,
        orchestrator_error: nil
      }

      assert %Phoenix.LiveView.Socket{} = out = AdminLive.assign_rehydrate_flash(socket, meta)

      # No flash_error written.
      assert is_nil(out.assigns.flash_error) or out.assigns.flash_error == nil
    end
  end

  describe ":pending status — info-style flash" do
    test "pending meta sets flash_error with the pending text" do
      socket = fresh_socket()

      meta = %{
        orchestrator_uri: URI.new!("entity://agent/system/cc_orchestrator-main"),
        orchestrator_status: :pending,
        orchestrator_error: nil
      }

      out = AdminLive.assign_rehydrate_flash(socket, meta)
      flash = out.assigns.flash_error

      assert is_binary(flash)
      assert flash =~ "pending"
      assert flash =~ "rehydrate"
    end
  end

  describe ":failed status — error-style flash" do
    test "failed meta sets flash_error with the failure reason" do
      socket = fresh_socket()
      reason = {:sandbox_write_path_failed, "details"}

      meta = %{
        orchestrator_uri: nil,
        orchestrator_status: :failed,
        orchestrator_error: reason
      }

      out = AdminLive.assign_rehydrate_flash(socket, meta)
      flash = out.assigns.flash_error

      assert is_binary(flash)
      assert flash =~ "failed"
      assert flash =~ "Restart"
      # The reason term is included via `inspect/1`.
      assert flash =~ "sandbox_write_path_failed"
    end
  end

  describe "unknown / nil meta — no flash change" do
    test "non-map meta is a no-op" do
      socket = fresh_socket()
      assert ^socket = AdminLive.assign_rehydrate_flash(socket, nil)
    end

    test "map without :orchestrator_status key is a no-op" do
      socket = fresh_socket()
      out = AdminLive.assign_rehydrate_flash(socket, %{})
      assert is_nil(out.assigns.flash_error) or out.assigns.flash_error == nil
    end
  end
end
