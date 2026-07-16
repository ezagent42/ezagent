defmodule Ezagent.DomainGit.ChangeLimitsTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{ChangeLimits, FileChange}

  setup do
    previous = Application.get_env(:ezagent_domain_git, :change_limits, :absent)
    on_exit(fn -> restore(previous) end)
    Application.delete_env(:ezagent_domain_git, :change_limits)
    :ok
  end

  test "defaults and exact configured values are closed" do
    assert {:ok,
            %ChangeLimits{max_files: 100, max_file_bytes: 1_000_000, max_total_bytes: 5_000_000}} =
             ChangeLimits.current()

    Application.put_env(:ezagent_domain_git, :change_limits, %{
      max_files: 1,
      max_file_bytes: 2,
      max_total_bytes: 3
    })

    assert {:ok, %ChangeLimits{max_files: 1}} = ChangeLimits.current()
  end

  test "invalid explicit config never falls back or raises" do
    for config <- [
          %{},
          %{max_files: 1, max_file_bytes: 2, max_total_bytes: 3, extra: 4},
          %{max_files: 0, max_file_bytes: 2, max_total_bytes: 3},
          %{max_files: 1, max_file_bytes: "2", max_total_bytes: 3}
        ] do
      Application.put_env(:ezagent_domain_git, :change_limits, config)
      assert ChangeLimits.current() == {:error, :invalid_change_limits_config}
    end
  end

  test "validate_many enforces count, per-file, total, and propagates config errors" do
    {:ok, a} = FileChange.new(%{path: "a", operation: :upsert, content: "12"})
    {:ok, b} = FileChange.new(%{path: "b", operation: :upsert, content: "34"})

    Application.put_env(:ezagent_domain_git, :change_limits, %{
      max_files: 1,
      max_file_bytes: 3,
      max_total_bytes: 3
    })

    assert FileChange.validate_many([]) == {:error, :invalid_file_change}
    assert FileChange.validate_many([a, b]) == {:error, :change_limit_exceeded}

    assert FileChange.validate_many([
             struct!(FileChange, path: "a", operation: :upsert, content: "1234")
           ]) == {:error, :change_limit_exceeded}

    Application.put_env(:ezagent_domain_git, :change_limits, %{
      max_files: 2,
      max_file_bytes: 3,
      max_total_bytes: 3
    })

    assert FileChange.validate_many([a, b]) == {:error, :change_limit_exceeded}
    Application.put_env(:ezagent_domain_git, :change_limits, %{})
    assert FileChange.validate_many([a]) == {:error, :invalid_change_limits_config}
  end

  test "validate_many rejects forged FileChange structs without raising" do
    forged = [
      struct!(FileChange, path: "a", operation: :upsert, content: nil),
      struct!(FileChange, path: "a", operation: :upsert, content: 123),
      struct!(FileChange, path: "../a", operation: :upsert, content: "x"),
      struct!(FileChange, path: "a", operation: :delete, content: "x"),
      struct!(FileChange, path: "a", operation: :upsert, content: <<255>>)
    ]

    for change <- forged do
      assert FileChange.validate_many([change]) == {:error, :invalid_file_change}
    end
  end

  defp restore(:absent), do: Application.delete_env(:ezagent_domain_git, :change_limits)
  defp restore(value), do: Application.put_env(:ezagent_domain_git, :change_limits, value)
end
