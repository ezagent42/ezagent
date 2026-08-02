defmodule Ezagent.Sandbox.GitIdentityDirTest do
  use ExUnit.Case, async: true

  alias Ezagent.Resource.FsResolver
  alias Ezagent.Sandbox.GitIdentityDir

  defp agent(ws, name), do: Ezagent.URI.entity(ws, :agent, name)

  describe "path/1" do
    test "同一 agent 幂等" do
      uri = agent(:acme, "worker-1")
      assert GitIdentityDir.path(uri) == GitIdentityDir.path(uri)
    end

    test "不同 agent / 不同 workspace 解析到不同目录" do
      a = GitIdentityDir.path(agent(:acme, "worker-1"))
      b = GitIdentityDir.path(agent(:acme, "worker-2"))
      c = GitIdentityDir.path(agent(:other, "worker-1"))

      assert a != b
      assert a != c
      assert b != c
    end

    test "解析结果落在 git-identity backend 下，且带 ws/name 两级" do
      path = GitIdentityDir.path(agent(:acme, "worker-1"))

      assert String.contains?(path, "git-identity")
      assert Path.basename(path) == "worker-1"
      assert path |> Path.dirname() |> Path.basename() == "acme"
    end

    test "非 agent URI 直接 raise，绝不静默给一个默认目录" do
      assert_raise ArgumentError, fn ->
        GitIdentityDir.path(Ezagent.URI.entity(:acme, :user, "someone"))
      end
    end
  end

  describe "safe_to_destroy?/2" do
    test "规范路径为 true" do
      uri = agent(:acme, "worker-1")
      assert GitIdentityDir.safe_to_destroy?(GitIdentityDir.path(uri), uri)
    end

    test "别的 agent 的目录为 false" do
      uri = agent(:acme, "worker-1")
      other = GitIdentityDir.path(agent(:acme, "worker-2"))
      refute GitIdentityDir.safe_to_destroy?(other, uri)
    end

    test "非字符串为 false" do
      refute GitIdentityDir.safe_to_destroy?(nil, agent(:acme, "worker-1"))
    end
  end

  describe "结构保证：git-identity 不得被认作 config-dir 家族" do
    # 这条是 spec §1.2 的结构保证。config_dir_type?/1 按 authority 函数
    # 的**身份**判定家族成员；一旦两者共用同一个函数，git-identity 目录
    # 就会被 credential-cascade 的层机制认领，未获授权的 agent 会经
    # cp_r 拿到别人的 SSH 私钥。
    test "git_identity_authority/2 与 config_dir_authority/2 不是同一个函数" do
      refute Function.capture(FsResolver, :git_identity_authority, 2) ==
               Function.capture(FsResolver, :config_dir_authority, 2)
    end

    test "已注册的 git-identity type 的 authority 就是 git_identity_authority/2" do
      [{_type, spec}] = :ets.lookup(FsResolver.table(), GitIdentityDir.type())

      assert spec.authority == Function.capture(FsResolver, :git_identity_authority, 2)
      assert spec.backend_component == GitIdentityDir.type()
    end
  end

  describe "git_identity_authority/2" do
    test "URI 的 ws 与 scope.workspace 一致时通过" do
      uri = Ezagent.URI.resource(:acme, GitIdentityDir.type(), "worker-1")
      assert :ok == FsResolver.git_identity_authority(uri, %{workspace: "acme"})
    end

    test "伪造的跨 workspace resource URI 被拒（fail loud，不是 :none）" do
      uri = Ezagent.URI.resource(:victim, GitIdentityDir.type(), "worker-1")
      assert {:error, _} = FsResolver.git_identity_authority(uri, %{workspace: "acme"})
    end
  end
end
