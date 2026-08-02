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

  describe "missing_hosts/2（H1/M6，Task 5 复审）" do
    test "全部请求的 host 都在 scan 输出里 —— 无缺失" do
      scanned = "github.com ssh-ed25519 AAAA\ngitlab.com ssh-ed25519 BBBB\n"
      assert [] = KnownHosts.missing_hosts(["github.com", "gitlab.com"], scanned)
    end

    # H1 红演示场景：请求两个 host、scan 输出只含其一（`ssh-keyscan` 对"部分
    # 主机不可达"的真实退出码语义是 exit 0 —— 不需要真的去 keyscan 一个不可
    # 达主机，直接喂这个函数一份"看起来正常但缺一行"的输出）。
    test "scan 输出只含其一 —— 缺失的那个被点名" do
      scanned = "github.com ssh-ed25519 AAAA\n"

      assert ["gitlab.internal"] =
               KnownHosts.missing_hosts(["github.com", "gitlab.internal"], scanned)
    end

    test "scan 输出为空 —— 全部请求的 host 都算缺失" do
      assert ["github.com", "gitlab.com"] =
               KnownHosts.missing_hosts(["github.com", "gitlab.com"], "")
    end

    test "scan 输出含额外的 host（未请求）不影响缺失判定" do
      scanned = "github.com ssh-ed25519 AAAA\nsome-other-host.example ssh-ed25519 CCCC\n"
      assert [] = KnownHosts.missing_hosts(["github.com"], scanned)
    end
  end

  describe "run_keyscan/1（H2，Task 5 复审）" do
    # 与 apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
    # 的 "ssh-keygen 缺失时返回 keygen_failed，不 crash" 同一手法（该文件本身
    # 引用为先例）：清空 PATH 让 System.cmd 真实抛 :enoent，而不是 mock 行为。
    # 修复前，这条断言无法通过——不是因为返回值错，而是因为 EXIT 信号经
    # Task.async 的 link 把这个测试进程本身也拖死，断言根本没机会跑。
    test "ssh-keyscan 缺失时返回 {:error, {:ssh_keyscan_unavailable, _}}，不 crash 调用进程" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

      try do
        assert {:error, {:ssh_keyscan_unavailable, _reason}} =
                 KnownHosts.run_keyscan(["github.com"])
      after
        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end
    end
  end
end
