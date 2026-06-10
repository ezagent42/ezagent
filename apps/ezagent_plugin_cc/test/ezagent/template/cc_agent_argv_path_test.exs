defmodule Ezagent.PluginCc.Template.CcAgentArgvPathTest do
  @moduledoc """
  Regression test for the codex review of the PR-1 hardening (#233).

  The hardening refactored the `claude` invocation from a shell string
  to an argv list (`[cmd | args]`). erlexec's list-form `:exec.run/2`
  runs `execve(3)` directly — NO shell, hence NO `$PATH` search. A bare
  `"claude"` as argv element 0 therefore resolves only if `claude`
  lives in `cwd`, regressing production cc startup (the pre-#233
  shell-string path resolved `claude` via `$PATH`).

  The fix: `CcAgent.resolve_claude_executable/1` resolves `claude` to
  an absolute path via `System.find_executable/1`, returning
  `{:error, :claude_not_found}` (no silent shell fallback) when it is
  not on `PATH`.

  These tests:

  1. `resolve_claude_executable/1` finds a PATH-installed binary and
     returns its absolute path.
  2. `resolve_claude_executable/1` returns `{:error, :claude_not_found}`
     when `claude` is not resolvable — no shell fallback.
  3. **The codex explicit ask** — a resolved absolute path, used as
     argv element 0 of a list-form `:exec.run/2`, ACTUALLY STARTS the
     OS process. This proves the fix end-to-end: not just arg
     assembly, but that erlexec's no-shell `execve` path launches a
     real PATH-installed binary once element 0 is resolved.

  `async: false` — the tests mutate the global `PATH` env var.
  """
  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  @agent_uri Ezagent.URI.new!("entity://team-alpha/agent/cc_argv-path-test")

  setup do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end
    end)

    # A temp dir that will hold a mock `claude` executable. Tests that
    # need a PATH-installed `claude` prepend this dir to PATH.
    bin_dir =
      Path.join(
        System.tmp_dir!(),
        "cc_argv_path_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bin_dir)
    on_exit(fn -> File.rm_rf(bin_dir) end)

    {:ok, original_path: original_path, bin_dir: bin_dir}
  end

  # Write a mock `claude` executable into `dir` that prints a marker
  # line and exits 0 — enough to prove the process actually launched.
  defp install_mock_claude!(dir) do
    path = Path.join(dir, "claude")

    File.write!(path, """
    #!/usr/bin/env bash
    echo "MOCK-CLAUDE-STARTED"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  describe "resolve_claude_executable/1 — PATH resolution (codex #233 review)" do
    test "resolves `claude` on PATH to an absolute path", %{
      original_path: original_path,
      bin_dir: bin_dir
    } do
      mock_path = install_mock_claude!(bin_dir)
      System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

      assert {:ok, resolved} = CcAgent.resolve_claude_executable(@agent_uri)

      # The resolved value MUST be an absolute path — erlexec's
      # list-form execve cannot search PATH itself.
      assert Path.type(resolved) == :absolute
      assert resolved == mock_path
      # And it must NOT be the bare program name (the #233 regression).
      refute resolved == "claude"
    end

    test "returns {:error, :claude_not_found} when `claude` is not on PATH — no shell fallback",
         %{bin_dir: bin_dir} do
      # PATH points only at an empty dir → `claude` is unresolvable.
      System.put_env("PATH", bin_dir)
      refute File.exists?(Path.join(bin_dir, "claude"))

      assert {:error, :claude_not_found} = CcAgent.resolve_claude_executable(@agent_uri)
    end
  end

  describe "list-form :exec.run/2 starts a PATH-installed binary (codex explicit ask)" do
    @tag :requires_exec
    test "a resolved absolute path used as argv element 0 actually launches the OS process", %{
      original_path: original_path,
      bin_dir: bin_dir
    } do
      case :application.ensure_all_started(:erlexec) do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("erlexec unavailable: #{inspect(reason)}")
      end

      # 1. Install a mock executable named `claude` ON PATH.
      install_mock_claude!(bin_dir)
      System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

      # 2. Resolve it through the SAME production code path the fix
      #    uses — `System.find_executable/1` via resolve_claude_executable/1.
      assert {:ok, resolved} = CcAgent.resolve_claude_executable(@agent_uri)
      assert Path.type(resolved) == :absolute

      # 3. Build a list-form (argv) command with the resolved path as
      #    element 0 — exactly the shape build_claude_cmd/3 hands to
      #    Ezagent.Domain.Pty.Server, exactly the shape the Server
      #    passes to :exec.run/2. erlexec runs this via execve(3) with
      #    NO shell and NO PATH search.
      argv = [String.to_charlist(resolved)]

      # 4. Run it via list-form :exec.run/2 and prove it ACTUALLY
      #    STARTS — this is the codex ask: not arg assembly, a real
      #    launch. A bare ["claude"] here would fail (no PATH search);
      #    the resolved absolute path succeeds and runs to exit 0.
      #    `:sync` returns `{:ok, [stdout: [...]]}` on exit 0.
      assert {:ok, output} = :exec.run(argv, [:stdout, :stderr, :sync])

      stdout =
        output
        |> Keyword.get(:stdout, [])
        |> IO.iodata_to_binary()

      # The mock printed its start marker — proof the binary actually
      # ran, not just that the argv was assembled.
      assert stdout =~ "MOCK-CLAUDE-STARTED",
             "the resolved-path argv must actually launch the binary — got stdout: #{inspect(stdout)}"
    end

    @tag :requires_exec
    test "a bare program name (the #233 regression) fails to launch under list-form execve", %{
      bin_dir: bin_dir
    } do
      case :application.ensure_all_started(:erlexec) do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("erlexec unavailable: #{inspect(reason)}")
      end

      install_mock_claude!(bin_dir)
      # PATH includes the mock dir — but it does NOT matter: list-form
      # :exec.run runs execve directly and never consults PATH.
      System.put_env("PATH", bin_dir)

      # Bare program name as argv element 0 — the #233 regression.
      result = :exec.run([~c"claude"], [:stdout, :stderr, :sync])

      # execve with a non-absolute, non-cwd-relative name → "cannot
      # execute 'claude': No such file or directory" → {:error, ...}.
      # The invariant: list-form exec does NOT search PATH, so a bare
      # name does NOT launch.
      refute match?({:ok, _}, result),
             "bare `claude` must NOT launch under list-form execve (no PATH search) — got: #{inspect(result)}"
    end
  end
end
