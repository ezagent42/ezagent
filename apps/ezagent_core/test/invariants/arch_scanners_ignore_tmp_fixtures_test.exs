defmodule EzagentCore.Invariants.ArchScannersIgnoreTmpFixturesTest do
  @moduledoc """
  The architecture gates glob `apps/**/*.ex`. ExUnit roots `@tag :tmp_dir` at
  `<cwd>/tmp/...`, which in this umbrella is `apps/<app>/tmp/` — inside the glob.

  So the gates were reading another test's scratch files as production source.
  That produced an intermittent `File.Error` (the fixture is deleted by its
  owning test mid-scan) and, worse, a latent FALSE POSITIVE: the fixtures
  `GitAdapterBoundaryTest` plants are deliberate bypass samples, so a scan that
  won the race instead of losing it would report a violation living only in
  another test's temp directory.

  This pins the exclusion itself rather than any one gate, because the hole was
  copied across six hand-rolled scanners and the next one written will copy it
  again unless the reason is written down somewhere a person will read.
  """

  use ExUnit.Case, async: false

  alias EzagentCore.AstScan

  defp repo_root do
    __DIR__ |> Path.join("../../../..") |> Path.expand()
  end

  describe "AstScan.tmp_fixture?/1" do
    test "recognises an ExUnit tmp_dir path inside the umbrella" do
      assert AstScan.tmp_fixture?(
               "/repo/apps/ezagent_core/tmp/SomeTest/a-case/apps/probe/lib/probe.ex"
             )
    end

    test "leaves real source alone" do
      refute AstScan.tmp_fixture?("/repo/apps/ezagent_core/lib/ezagent/uri.ex")
      refute AstScan.tmp_fixture?("/repo/apps/ezagent_plugin_github/lib/x/github_adapter.ex")
    end
  end

  # The behavioural half: a file planted where a `:tmp_dir` fixture lands must
  # not survive the rejection every scanner now applies. Asserted against a real
  # `Path.wildcard/1` over the real tree so a glob change cannot quietly
  # invalidate it.
  @tag :tmp_dir
  test "a file planted under an app's tmp/ is not enumerated as source" do
    root = repo_root()
    planted = Path.join([root, "apps", "ezagent_core", "tmp", "ScannerProbe", "lib", "probe.ex"])

    File.mkdir_p!(Path.dirname(planted))

    on_exit(fn ->
      File.rm_rf!(Path.join([root, "apps", "ezagent_core", "tmp", "ScannerProbe"]))
    end)

    File.write!(planted, "defmodule ScannerProbe do\n  def x, do: :ok\nend\n")

    enumerated =
      ["apps/**/*.ex"]
      |> Enum.flat_map(&(root |> Path.join(&1) |> Path.wildcard()))
      |> Enum.reject(&String.contains?(&1, "/test/"))

    # Without this the next assertion is vacuous: if the glob stopped reaching
    # `apps/<app>/tmp/` the exclusion would have nothing to do and the test
    # would pass while proving nothing.
    assert planted in enumerated,
           "fixture setup is broken — the glob no longer reaches apps/<app>/tmp/"

    refute planted in Enum.reject(enumerated, &AstScan.tmp_fixture?/1),
           "the tmp exclusion did not remove the planted fixture"
  end
end
