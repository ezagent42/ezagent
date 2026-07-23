defmodule EzagentDomainGit.ApplicationStartTest do
  use ExUnit.Case, async: false

  test "invalid limits fail before starting a supervisor" do
    previous = Application.get_env(:ezagent_domain_git, :change_limits, :absent)
    existing_supervisor = Process.whereis(EzagentDomainGit.Application)
    on_exit(fn -> restore(previous) end)
    Application.put_env(:ezagent_domain_git, :change_limits, %{})

    assert EzagentDomainGit.Application.start(:normal, []) ==
             {:error, :invalid_change_limits_config}

    assert Process.whereis(EzagentDomainGit.Application) == existing_supervisor
  end

  defp restore(:absent), do: Application.delete_env(:ezagent_domain_git, :change_limits)
  defp restore(value), do: Application.put_env(:ezagent_domain_git, :change_limits, value)
end
