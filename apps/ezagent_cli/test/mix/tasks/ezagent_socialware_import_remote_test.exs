defmodule Mix.Tasks.Ezagent.Socialware.ImportRemoteTest do
  @moduledoc """
  D5 正路 RPC 导入 task 的本地面单元测:参数校验 / 文件读取 / `--dry-run`
  解析路径 / cookie 解析失败 loud。真正的 erpc 发布链在运行节点内跑
  (`ManifestSeed.import_package/2`,domain_session 集成测覆盖),task 侧
  不 mock 分布式连接。
  """

  use ExUnit.Case, async: false

  @task Mix.Tasks.Ezagent.Socialware.ImportRemote

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "import-remote-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_manifest!(dir, name) do
    path = Path.join(dir, "manifest.yaml")

    File.write!(path, """
    name: #{name}
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    """)

    path
  end

  test "无参数 → loud usage 错误" do
    assert_raise Mix.Error, ~r/exactly one <manifest.yaml>/, fn ->
      @task.run([])
    end
  end

  test "未知选项 → loud 错误" do
    assert_raise Mix.Error, ~r/unknown options/, fn ->
      @task.run(["m.yaml", "--bogus"])
    end
  end

  test "manifest 文件不存在 → loud 错误" do
    assert_raise Mix.Error, ~r/cannot read manifest/, fn ->
      @task.run(["/nonexistent/manifest.yaml", "--dry-run"])
    end
  end

  test "--dry-run 解析 manifest + 同目录 recipes.yaml,零发布零连接" do
    dir = tmp_dir!()
    path = write_manifest!(dir, "dry-run-demo")

    File.write!(Path.join(dir, "recipes.yaml"), """
    recipes:
      - name: demo-brain
        skills:
          - demo-skill
        prompt: |
          你是 demo 脑。
    """)

    @task.run([path, "--dry-run"])

    assert_received {:mix_shell, :info, [msg1]}
    assert msg1 =~ "name: dry-run-demo"
    assert_received {:mix_shell, :info, [msg2]}
    assert msg2 =~ "recipes: demo-brain"
    assert_received {:mix_shell, :info, [msg3]}
    assert msg3 =~ "nothing published"
  end

  test "--dry-run 无同目录 recipes.yaml 时明说" do
    dir = tmp_dir!()
    path = write_manifest!(dir, "dry-run-solo")

    @task.run([path, "--dry-run"])

    assert_received {:mix_shell, :info, [_name_line]}
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "no sibling recipes.yaml"
  end

  test "--dry-run:manifest 缺 name → loud 错误" do
    dir = tmp_dir!()
    path = Path.join(dir, "manifest.yaml")
    File.write!(path, "version: 1\n")

    assert_raise Mix.Error, ~r/no usable `name`/, fn ->
      @task.run([path, "--dry-run"])
    end
  end

  test "--dry-run:recipes.yaml 非 recipes: 列表 → loud 错误" do
    dir = tmp_dir!()
    path = write_manifest!(dir, "dry-run-bad-recipes")
    File.write!(Path.join(dir, "recipes.yaml"), "not_recipes: []\n")

    assert_raise Mix.Error, ~r/top-level `recipes:` list/, fn ->
      @task.run([path, "--dry-run"])
    end
  end

  test "非 dry-run:cookie 文件缺失 → loud 错误(未触发任何连接)" do
    dir = tmp_dir!()
    path = write_manifest!(dir, "no-cookie-demo")

    saved = System.get_env("EZAGENT_COOKIE")
    System.delete_env("EZAGENT_COOKIE")
    on_exit(fn -> if saved, do: System.put_env("EZAGENT_COOKIE", saved) end)

    assert_raise Mix.Error, ~r/cannot read cookie file/, fn ->
      @task.run([path, "--cookie-file", Path.join(dir, "absent-cookie")])
    end
  end
end
