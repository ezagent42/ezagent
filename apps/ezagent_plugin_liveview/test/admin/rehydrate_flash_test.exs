defmodule EzagentPluginLiveview.Admin.RehydrateFlashTest do
  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.Admin.RehydrateFlash

  defp fresh_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash_error: nil}
    }
  end

  test "ready meta leaves flash_error untouched" do
    socket = fresh_socket()

    out =
      RehydrateFlash.assign(socket, %{
        orchestrator_status: :ready,
        orchestrator_error: nil
      })

    assert is_nil(out.assigns.flash_error)
  end

  test "plain sessions without an orchestrator do not show a failure flash" do
    socket = fresh_socket()

    out =
      RehydrateFlash.assign(socket, %{
        orchestrator_status: :failed,
        orchestrator_error: :no_orchestrator
      })

    assert is_nil(out.assigns.flash_error)
  end

  test "failed orchestrator rehydrate shows the inspected failure reason" do
    out =
      RehydrateFlash.assign(fresh_socket(), %{
        orchestrator_status: :failed,
        orchestrator_error: {:sandbox_write_path_failed, "details"}
      })

    assert out.assigns.flash_error =~ "Orchestrator failed"
    assert out.assigns.flash_error =~ "sandbox_write_path_failed"
  end

  test "non-map meta is a no-op" do
    socket = fresh_socket()
    assert ^socket = RehydrateFlash.assign(socket, nil)
  end
end
