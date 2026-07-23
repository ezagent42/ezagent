defmodule EzagentCore.Invariants.NoLegacyFilesRouteTest do
  @moduledoc """
  Resource-unification P2 invariant — the legacy `/files/:filename` upload
  download route is FULLY RETIRED (Allen-approved 2026-06-08), with NO
  back-compat shim.

  This scans ALL runtime `lib/` Elixir/HEEx sources across the umbrella and
  asserts ZERO `/files/...` upload-link emitters survive — neither a router
  declaration (`get "/files/..."`) nor any link-builder string
  (`"/files/\#{...}"`, `~p"/files/..."`, etc). The SOLE download surface is the
  token-authorized `/uploads/download?token=` route; the in-session LiveView
  mints that token via `Ezagent.Uploads.DownloadToken`.

  Test sources are excluded — a removed-route regression test legitimately names
  the old path to assert it 404s.
  """
  use ExUnit.Case, async: true

  test "no runtime lib source emits or declares a /files upload route or link" do
    offenders =
      lib_sources()
      |> Enum.flat_map(&files_references/1)

    assert offenders == [],
           """
           Found surviving `/files` upload-route references after P2 retirement:

           #{Enum.join(offenders, "\n")}

           The legacy `/files/:filename` route is gone with no shim. Upload
           downloads must use `/uploads/download?token=` (the token minted via
           Ezagent.Uploads.DownloadToken). Remove the offending route/link.
           """
  end

  defp lib_sources do
    Path.join([apps_root(), "**", "lib", "**", "*.{ex,heex}"])
    |> Path.wildcard()
    # Exclude transient per-test fixtures under any `tmp/` dir (e.g. the
    # GitAdapterBoundaryTest planted-repo fixtures): a sibling test can delete
    # them mid-stream, raising File.Error here. Production lib sources are never
    # under `tmp/`.
    |> Enum.reject(&String.contains?(&1, "/tmp/"))
    |> Enum.sort()
  end

  # Match a `/files/` path used as a CODE route declaration or link target: a
  # string literal (`"/files/...`) or a verified-route sigil (`~p"/files/...`).
  # Prose in `#` comments and `@moduledoc` text writes `/files/:filename` WITHOUT
  # a leading quote, so it is not matched — only live route/link strings are.
  @pattern ~r/~?p?"\/files\//

  defp files_references(path) do
    path
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> Regex.match?(@pattern, line) end)
    |> Enum.map(fn {line, n} ->
      "#{Path.relative_to(path, repo_root())}:#{n}: #{String.trim(line)}"
    end)
  end

  defp apps_root, do: Path.join(repo_root(), "apps")

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {top, 0} ->
        String.trim(top)

      _ ->
        cwd = File.cwd!()
        if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
    end
  end
end
