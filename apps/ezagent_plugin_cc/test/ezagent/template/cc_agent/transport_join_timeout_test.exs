defmodule Ezagent.PluginCc.Template.CcAgent.TransportJoinTimeoutTest do
  @moduledoc """
  Phase 3 ③ T7h Part B — the cc transport-join gate timeout is operator
  configurable via `config :ezagent_plugin_cc, :transport_join_timeout_ms`,
  defaulting (unchanged) to 30s. act4 evidence (发现 1) proved cc claude
  cold-start to bridge JOIN measured 50–85s under load — far past the old
  hard-coded 30s — so a knob is required to let e2e/operators raise it without
  patching source.
  """

  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent.Spawn

  setup do
    prev = Application.get_env(:ezagent_plugin_cc, :transport_join_timeout_ms)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezagent_plugin_cc, :transport_join_timeout_ms)
        val -> Application.put_env(:ezagent_plugin_cc, :transport_join_timeout_ms, val)
      end
    end)

    :ok
  end

  test "defaults to 30_000ms when unconfigured (no behavior change)" do
    Application.delete_env(:ezagent_plugin_cc, :transport_join_timeout_ms)
    assert Spawn.transport_join_timeout_ms() == 30_000
  end

  test "honors an operator-configured override" do
    Application.put_env(:ezagent_plugin_cc, :transport_join_timeout_ms, 240_000)
    assert Spawn.transport_join_timeout_ms() == 240_000
  end
end
