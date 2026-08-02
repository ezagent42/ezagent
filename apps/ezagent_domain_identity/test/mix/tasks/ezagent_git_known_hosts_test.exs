defmodule Mix.Tasks.Ezagent.Git.KnownHostsTest do
  # async: false —— `plan/1` reads the GLOBAL `Application.get_env(:ezagent_core,
  # :git_known_hosts_path)` (via `GitIdentityRuntime.known_hosts_path/0`), the
  # exact same key `git_identity_runtime_test.exs` and `agent_git_identity_test.exs`
  # mutate via `Application.put_env/3` — both of those files are themselves
  # `async: false` for this reason. No config in `config/test.exs` sets this key
  # (confirmed by grep), so "既没有 --out 也没有配置项时" only holds deterministically
  # if this file cannot run concurrently with a test that is mid-mutation of it.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ezagent.Git.KnownHosts

  describe "参数解析" do
    test "没给 host 时报错" do
      assert {:error, :no_hosts} = KnownHosts.plan([])
    end

    test "既没有 --out 也没有配置项时，要求显式给 --out" do
      assert {:error, :no_output_path} = KnownHosts.plan(["github.com"])
    end

    test "--out 指定输出路径" do
      assert {:ok, %{hosts: ["github.com"], out: "/tmp/kh"}} =
               KnownHosts.plan(["github.com", "--out", "/tmp/kh"])
    end

    test "多个 host" do
      assert {:ok, %{hosts: ["github.com", "gitlab.com"]}} =
               KnownHosts.plan(["github.com", "gitlab.com", "--out", "/tmp/kh"])
    end
  end

  describe "写入" do
    test "把 scan 结果写到 out 路径并 chmod 0644" do
      out = Path.join(System.tmp_dir!(), "kh-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      assert :ok = KnownHosts.write_scanned(out, "github.com ssh-ed25519 AAAA\n")

      assert File.read!(out) == "github.com ssh-ed25519 AAAA\n"
      {:ok, %File.Stat{mode: mode}} = File.stat(out)
      assert Bitwise.band(mode, 0o777) == 0o644
    end

    test "空的 scan 结果被拒 —— 绝不写出一个空 known_hosts" do
      out = Path.join(System.tmp_dir!(), "kh-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      assert {:error, :empty_scan} = KnownHosts.write_scanned(out, "")
      assert {:error, :empty_scan} = KnownHosts.write_scanned(out, "   \n\n")
      refute File.exists?(out)
    end
  end
end
