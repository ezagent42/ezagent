defmodule Mix.Tasks.Ezagent.UriQuery.ScanTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("ezagent.uri_query.scan")
    :ok
  end

  test "defaults to hard-fail and passes when the source tree is clean" do
    output =
      capture_io(fn ->
        assert :ok = Mix.Task.rerun("ezagent.uri_query.scan", [])
      end)

    assert output =~ "ezagent.uri_query.scan"
    assert output =~ "hard-fail"
    assert output =~ "no URI-query scan violations"
  end

  test "--hard-fail is accepted for explicit CI wiring" do
    output =
      capture_io(fn ->
        assert :ok = Mix.Task.rerun("ezagent.uri_query.scan", ["--hard-fail"])
      end)

    assert output =~ "hard-fail"
    assert output =~ "no URI-query scan violations"
  end

  test "--fail-category remains accepted when the selected category is zero" do
    output =
      capture_io(fn ->
        assert :ok =
                 Mix.Task.rerun("ezagent.uri_query.scan", [
                   "--fail-category",
                   "flavor_prefix_dependency"
                 ])
      end)

    assert output =~ "hard-fail"
    assert output =~ "no URI-query scan violations"
  end
end
