defmodule Ezagent.Credential.GitIdentityRuntimeTest do
  # async: false —— 改 Application env（:git_known_hosts_path）
  use ExUnit.Case, async: false

  alias Ezagent.Credential.GitIdentityRuntime
  alias Ezagent.Sandbox.GitIdentityDir

  @key_a "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA-a\n-----END OPENSSH PRIVATE KEY-----\n"
  @key_b "-----BEGIN OPENSSH PRIVATE KEY-----\nBBBB-b\n-----END OPENSSH PRIVATE KEY-----\n"

  setup do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "w-#{suffix}")

    kh_dir = Path.join(System.tmp_dir!(), "ezagent-kh-#{suffix}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")
    File.write!(kh_path, "github.com ssh-ed25519 AAAAFAKE\n")

    prev = Application.get_env(:ezagent_core, :git_known_hosts_path)
    Application.put_env(:ezagent_core, :git_known_hosts_path, kh_path)

    on_exit(fn ->
      if prev do
        Application.put_env(:ezagent_core, :git_known_hosts_path, prev)
      else
        Application.delete_env(:ezagent_core, :git_known_hosts_path)
      end

      File.rm_rf(kh_dir)
      File.rm_rf(GitIdentityDir.path(agent_uri))
    end)

    %{agent_uri: agent_uri, kh_path: kh_path}
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  describe "write/2 happy path" do
    test "私钥写入且 mode 恰为 0600，目录 0700", ctx do
      assert {:ok, _env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      dir = GitIdentityDir.path(ctx.agent_uri)
      key_path = Path.join(dir, "id_ed25519")

      assert File.read!(key_path) == @key_a
      assert mode(key_path) == 0o600
      assert mode(dir) == 0o700
    end

    test "known_hosts 从节点级文件复制进来，mode 恰为 0644（G5：此前从未断言）", ctx do
      assert {:ok, _env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      copied = Path.join(GitIdentityDir.path(ctx.agent_uri), "known_hosts")
      assert File.read!(copied) == File.read!(ctx.kh_path)
      assert mode(copied) == 0o644
    end

    test "覆写：第二次写的内容生效", ctx do
      assert {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      assert {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_b)

      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.read!(key_path) == @key_b
      assert mode(key_path) == 0o600
    end
  end

  describe "GIT_SSH_COMMAND —— 四个选项逐条断言" do
    setup ctx do
      {:ok, env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      %{cmd: Map.fetch!(env, "GIT_SSH_COMMAND"), dir: GitIdentityDir.path(ctx.agent_uri)}
    end

    test "env map 里只有 GIT_SSH_COMMAND 这一个 key", %{cmd: _} = ctx do
      {:ok, env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      assert Map.keys(env) == ["GIT_SSH_COMMAND"]
    end

    test "指向本 agent 自己的私钥，路径经 shell 单引号包裹（G2）", ctx do
      assert String.contains?(ctx.cmd, "-i '#{Path.join(ctx.dir, "id_ed25519")}'")
    end

    # 不加则 ssh 会把能找到的所有 key 挨个试，用错身份认证成功 → 审计归属错。
    test "IdentitiesOnly=yes", ctx do
      assert String.contains?(ctx.cmd, "-o IdentitiesOnly=yes")
    end

    # 不加则落到宿主 ssh-agent —— 那是运维本人的 key。最大的一条静默提权路径。
    test "IdentityAgent=none", ctx do
      assert String.contains?(ctx.cmd, "-o IdentityAgent=none")
    end

    # 不加则落到宿主 ~/.ssh/known_hosts，agent 之间互相污染。
    test "UserKnownHostsFile 指向本 agent 自己的副本，路径经 shell 单引号包裹（G2）", ctx do
      assert String.contains?(
               ctx.cmd,
               "-o UserKnownHostsFile='#{Path.join(ctx.dir, "known_hosts")}'"
             )
    end

    # 不加则 TOFU：首次连接无条件接受任何主机 key。
    test "StrictHostKeyChecking=yes", ctx do
      assert String.contains?(ctx.cmd, "-o StrictHostKeyChecking=yes")
    end
  end

  describe "known_hosts 未配置" do
    setup do
      Application.delete_env(:ezagent_core, :git_known_hosts_path)
      :ok
    end

    test "fail loud", ctx do
      assert {:error, :known_hosts_unconfigured} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)
    end

    test "且目录里没有私钥残留（不能留下一把用不了又拿得到的 key）", ctx do
      assert {:error, :known_hosts_unconfigured} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
    end
  end

  describe "known_hosts 配了但文件不存在" do
    setup do
      Application.put_env(
        :ezagent_core,
        :git_known_hosts_path,
        Path.join(System.tmp_dir!(), "definitely-not-here-#{System.unique_integer([:positive])}")
      )

      :ok
    end

    test "fail loud，且与未配置是不同的错误值", ctx do
      assert {:error, {:known_hosts_unreadable, _}} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)
    end
  end

  describe "G1① —— 成功写过一次后摘掉 known_hosts 配置，残留必须被清掉" do
    # codex 复审真跑复现：现有「known_hosts 未配置」两条测试都用全新目录，测
    # 不到"先前已有一把 key 躺在盘上"这个状态迁移。这条钉住设计 §6.1 的清理
    # 规则：write/2 除 {:ok, _} 外的每种结局都必须清空目录。
    test "第二次 write 返回 known_hosts_unconfigured，且第一次写的私钥不再存在", ctx do
      assert {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      Application.delete_env(:ezagent_core, :git_known_hosts_path)

      assert {:error, :known_hosts_unconfigured} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      refute File.exists?(key_path)
    end
  end

  describe "G1② —— known_hosts 写入失败时私钥不能已经落盘" do
    # opus 复审真跑复现（:eisdir 手法）：预先在目标位置 mkdir 一个叫
    # known_hosts 的目录，使 write_file(known_hosts) 必然以 :eisdir 失败。
    # known_hosts 现在先写、私钥最后写（design §6.1 point 2），所以私钥不应
    # 该在这次调用里被创建过。
    test "known_hosts 目标路径预先被一个同名目录占住", ctx do
      dir = GitIdentityDir.path(ctx.agent_uri)
      File.mkdir_p!(Path.join(dir, "known_hosts"))

      assert {:error, {:git_identity_write_failed, {"known_hosts", :eisdir}}} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      refute File.exists?(Path.join(dir, "id_ed25519"))
    end
  end

  describe "G2 —— GIT_SSH_COMMAND 路径必须扛住真实的 shell 拆词/展开" do
    # 最现实的触发（opus）：EZAGENT_HOME 含空格（本机就是 WSL，
    # /mnt/c/Users/John Doe/... 这类路径是真实场景，非构造）。
    test "EZAGENT_HOME 含空格：路径整体仍被单引号包住，不被词法切分", ctx do
      prev_home = System.get_env("EZAGENT_HOME")
      home = Path.join(System.tmp_dir!(), "ez agent home-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        File.rm_rf(home)
      end)

      System.put_env("EZAGENT_HOME", home)

      assert {:ok, env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      cmd = Map.fetch!(env, "GIT_SSH_COMMAND")
      dir = GitIdentityDir.path(ctx.agent_uri)

      # 确认这条测试真的在练空格场景，不是误配了一个没有空格的临时目录。
      assert String.contains?(dir, " ")
      assert String.contains?(cmd, "-i '#{Path.join(dir, "id_ed25519")}'")
      assert String.contains?(cmd, "-o UserKnownHostsFile='#{Path.join(dir, "known_hosts")}'")
    end

    # 同根的更锐利变体：Ezagent.URI.entity/3 的 segment!/1 只拒空串和 "/"，
    # 不拒 "$(...)"（两道复审各自实测确认）。agent 名里的 $(...) 若不被引
    # 号中和，会在 shell 解释 GIT_SSH_COMMAND 时触发命令替换。
    test "agent 名含 $(...)：不触发命令替换（路径被单引号包住）", _ctx do
      agent_uri =
        Ezagent.URI.entity(:gitid, :agent, "w$(id)-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(GitIdentityDir.path(agent_uri)) end)

      assert {:ok, env} = GitIdentityRuntime.write(agent_uri, @key_a)
      cmd = Map.fetch!(env, "GIT_SSH_COMMAND")
      dir = GitIdentityDir.path(agent_uri)

      assert String.contains?(dir, "$(id)")
      assert String.contains?(cmd, "-i '#{Path.join(dir, "id_ed25519")}'")
    end
  end

  describe "wipe/1" do
    test "删掉整个目录，且对不存在的目录幂等", ctx do
      {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      dir = GitIdentityDir.path(ctx.agent_uri)
      assert File.dir?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
      refute File.exists?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
    end

    test "非 agent URI 不抛异常（ArgumentError 分支）", _ctx do
      non_agent = Ezagent.URI.entity(:gitid, :user, "someone")
      assert :ok = GitIdentityRuntime.wipe(non_agent)
    end

    test "agent 名为 \"..\" 时不抛异常（G4：path/1 此时抛 RuntimeError，非 ArgumentError）", _ctx do
      # opus 真跑复现：Ezagent.URI.entity/3 不拒绝 "."/".." 段，所以这条 URI
      # 构造成功；FsResolver 的 unsafe-segment 拒绝让 GitIdentityDir.path/1
      # 抛 RuntimeError（不是 workspace_segment!/name_segment! 那条
      # ArgumentError 路径）。
      dotdot_agent = Ezagent.URI.entity(:gitid, :agent, "..")
      assert :ok = GitIdentityRuntime.wipe(dotdot_agent)
    end
  end
end
