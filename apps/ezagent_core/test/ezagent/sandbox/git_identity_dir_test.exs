defmodule Ezagent.Sandbox.GitIdentityDirTest do
  # F4 复审发现：`allocate/1` 的 EZAGENT_HOME override（`describe "allocate/1"`
  # 的 setup）读写进程全局的 `EZAGENT_HOME` 环境变量（镜像
  # `Ezagent.Sandbox.ConfigDirTest`），必须与同一测试运行中其它读该变量的套件
  # 串行 —— 故整文件改为 `async: false`（11 条测试代价可忽略）。
  use ExUnit.Case, async: false
  import Bitwise

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

  describe "allocate/1" do
    # F4 复审发现：`allocate/1` 与它的 0700 要求此前全仓零覆盖。镜像
    # `Ezagent.Sandbox.ConfigDirTest` "allocate/2" 的 EZAGENT_HOME override 手法。
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "ezagent-gitid-test-#{System.unique_integer([:positive])}"
        )

      prev = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", tmp)

      on_exit(fn ->
        if prev, do: System.put_env("EZAGENT_HOME", prev), else: System.delete_env("EZAGENT_HOME")
        File.rm_rf(tmp)
      end)

      :ok
    end

    test "创建目录，叶子目录 mode 恰为 0o700，重复调用幂等" do
      uri = agent(:acme, "worker-1")

      assert {:ok, target} = GitIdentityDir.allocate(uri)
      assert target == GitIdentityDir.path(uri)
      assert File.dir?(target)

      # 只断言叶子目录（<Home>/git-identity/<ws>/<name>，即 `target` 本身）。
      # `File.mkdir_p` 顺带建出的中间层 <Home>/git-identity/<ws>/ 从未被
      # chmod，走的是环境 umask（通常 0755）—— 不在这条断言的覆盖范围内，
      # 不要把这条读成"整条路径都是 0700"。
      assert {:ok, %File.Stat{mode: mode}} = File.stat(target)
      assert (mode &&& 0o777) == 0o700

      # 幂等：第二次调用是无害的 no-op
      assert {:ok, ^target} = GitIdentityDir.allocate(uri)
      assert File.dir?(target)
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

    test "非 agent URI + binary candidate 为 false，不 raise" do
      # F5 复审发现：safe_to_destroy?/2 的 @spec 承诺 :: boolean()，但
      # (binary candidate, 非 agent URI) 这一组合此前会经 path/1 抛
      # ArgumentError，而不是返回 false。
      non_agent = Ezagent.URI.entity(:acme, :user, "someone")
      refute GitIdentityDir.safe_to_destroy?("/some/path", non_agent)
    end
  end

  describe "结构保证：git-identity 不得被认作 config-dir 家族" do
    # 这条是 spec §1.2 的结构保证。config_dir_type?/1 按 authority 函数的
    # **身份**判定家族成员（fs_resolver.ex :301-304："families must NOT
    # share one fn reference"）；一旦两者共用同一个函数，git-identity 目录
    # 就会被 resolve_config_dir/1 判成 config-dir 类型 → {:error,
    # :config_dir_resource_requires_scope} → CascadeRuntime.layer_dirs/1 把
    # 它当致命中止（不是"跳过这层"），spawn 失败。（早前这里写的是"会经
    # cp_r 泄漏私钥"——查证后那条路径在当前代码下不可达，见
    # git_identity_dir.ex moduledoc 的更正。）
    test "已注册的 git-identity type 的 authority 就是 git_identity_authority/2" do
      [{_type, spec}] = :ets.lookup(FsResolver.table(), GitIdentityDir.type())

      assert spec.authority == Function.capture(FsResolver, :git_identity_authority, 2)
      assert spec.backend_component == GitIdentityDir.type()
    end

    test "真实消费者 config_dir_type?/1 判定 git-identity 为 false" do
      # F1 复审发现：上面那条断言只经由 ETS 里 authority 函数的具名捕获做
      # **传递性**证明，从未直接调用真实消费者
      # （uri_query_resolvers.ex:136 resolve_config_dir/1）实际调用的谓词。
      # 若 config_dir_type?/1 改成按显式类型名单（或新增的 family: 字段）
      # 判定、且把 "git-identity" 列进去，上面那条断言仍然全绿，但这条会抓到。
      refute FsResolver.config_dir_type?(GitIdentityDir.type())
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
