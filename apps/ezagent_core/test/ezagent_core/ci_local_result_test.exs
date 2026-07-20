defmodule EzagentCore.CiLocalResultTest do
  # async: false — mutates the process env var and the filesystem sentinel.
  use ExUnit.Case, async: false

  alias EzagentCore.CiLocalResult

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "ci_local_result_test_#{System.unique_integer([:positive])}.sentinel"
      )

    prev = System.get_env("EZAGENT_CI_LOCAL_SENTINEL")
    System.put_env("EZAGENT_CI_LOCAL_SENTINEL", path)
    File.rm_rf!(path)

    on_exit(fn ->
      File.rm_rf!(path)

      if prev,
        do: System.put_env("EZAGENT_CI_LOCAL_SENTINEL", prev),
        else: System.delete_env("EZAGENT_CI_LOCAL_SENTINEL")
    end)

    {:ok, path: path}
  end

  test "a clean suite leaves no sentinel and failed?/0 is false" do
    assert :ok = CiLocalResult.record_result(%{total: 10, failures: 0, excluded: 0, skipped: 0})
    refute CiLocalResult.failed?()
  end

  test "a suite with failures writes the sentinel and failed?/0 is true" do
    assert :ok = CiLocalResult.record_result(%{total: 10, failures: 2, excluded: 0, skipped: 0})
    assert CiLocalResult.failed?()
  end

  test "a setup_all crash folded into :failures is caught" do
    # ExUnit folds an invalid (setup_all crash) module into :failures.
    assert :ok = CiLocalResult.record_result(%{total: 2, failures: 1, excluded: 0, skipped: 0})
    assert CiLocalResult.failed?()
  end

  test "failures stay STICKY across the umbrella's many child suites" do
    assert :ok = CiLocalResult.record_result(%{total: 3, failures: 1})
    assert :ok = CiLocalResult.record_result(%{total: 5, failures: 0})
    assert CiLocalResult.failed?(), "a later clean child suite must not clear an earlier failure"
  end

  test "no-op (never blocks) when the sentinel env var is unset" do
    System.delete_env("EZAGENT_CI_LOCAL_SENTINEL")
    assert :ok = CiLocalResult.record_result(%{total: 5, failures: 5})
    refute CiLocalResult.failed?()
  end
end
