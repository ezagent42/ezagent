defmodule EzagentPluginGithub.CredsTest do
  @moduledoc """
  纯逻辑单测：github.yaml 凭证读写 round-trip（沙箱 EZAGENT_HOME，不打真 github）。
  """
  use ExUnit.Case, async: false

  alias EzagentPluginGithub.Creds

  # 每个测试一个独立临时 EZAGENT_HOME（写盘隔离，对齐 ezagent_core home_test idiom）。
  setup do
    tmp = Path.join(System.tmp_dir!(), "esr-gh-creds-#{System.unique_integer([:positive])}")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "default")

    on_exit(fn ->
      System.delete_env("EZAGENT_HOME")
      System.delete_env("EZAGENT_PROFILE")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "write 后 read round-trip：repo 空串 → nil" do
    assert :ok = Creds.write(%{access_token: "ghp_x", repo: ""})
    assert {:ok, %{token: "ghp_x", repo: nil}} = Creds.read()
  end

  test "write 带 repo → read 回 repo" do
    assert :ok = Creds.write(%{access_token: "ghp_y", repo: "owner/test-ezagent"})
    assert {:ok, %{token: "ghp_y", repo: "owner/test-ezagent"}} = Creds.read()
  end

  test "write 后落盘文件 chmod 0600" do
    assert :ok = Creds.write(%{access_token: "ghp_z"})

    file =
      Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "github.yaml"))

    assert File.exists?(file)
    %File.Stat{mode: mode} = File.stat!(file)
    # 取低 9 位权限，断属主-only 读写（0o600）。
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "无 access_token → :access_token_required（不写盘）" do
    assert {:error, :access_token_required} = Creds.write(%{repo: "owner/x"})
  end

  test "未配置（无文件）→ read 返回 :not_found" do
    assert {:error, :not_found} = Creds.read()
  end
end
