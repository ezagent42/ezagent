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

    test "known_hosts 从节点级文件复制进来", ctx do
      assert {:ok, _env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      copied = Path.join(GitIdentityDir.path(ctx.agent_uri), "known_hosts")
      assert File.read!(copied) == File.read!(ctx.kh_path)
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

    test "指向本 agent 自己的私钥", ctx do
      assert String.contains?(ctx.cmd, "-i #{Path.join(ctx.dir, "id_ed25519")}")
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
    test "UserKnownHostsFile 指向本 agent 自己的副本", ctx do
      assert String.contains?(
               ctx.cmd,
               "-o UserKnownHostsFile=#{Path.join(ctx.dir, "known_hosts")}"
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

  describe "wipe/1" do
    test "删掉整个目录，且对不存在的目录幂等", ctx do
      {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      dir = GitIdentityDir.path(ctx.agent_uri)
      assert File.dir?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
      refute File.exists?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
    end
  end
end
