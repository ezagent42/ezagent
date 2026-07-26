defmodule EzagentDomainPython.BootTest do
  @moduledoc """
  SPEC §9.3 (codex round-2 HIGH-2) — boot invariant.

  Application.ensure_all_started(:ezagent_domain_python) MUST bring up
  :erlexec too. If mix.exs drifts (drops :erlexec from
  extra_applications), this fails at precommit instead of at runtime.
  """

  use ExUnit.Case, async: false

  test "ensure_all_started includes erlexec" do
    assert {:ok, started} = Application.ensure_all_started(:ezagent_domain_python)
    started_or_already = (started ++ Application.started_applications()) |> Enum.map(&elem(&1, 0))
    assert :erlexec in started_or_already
  end

  test "Supervisor is alive after boot (private Registry retired — V5 A1b)" do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_python)
    assert Process.whereis(EzagentDomainPython.Supervisor) |> is_pid()
    # V5 pid-closure A1b: registration moved to the unified
    # `Ezagent.Runtime.SidecarRegistry` (actor app); the private
    # `EzagentDomainPython.Registry` is retired — nothing starts it.
    assert Process.whereis(Ezagent.Runtime.SidecarRegistry) |> is_pid()
  end
end
