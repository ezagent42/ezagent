defmodule Ezagent.Behavior.GithubTest do
  @moduledoc """
  网关 Behavior 契约单测（纯逻辑——不 shell out 真 gh）：

    * `actions/0` —— 8 个网关动作齐全（6 出站 + 2 入站 poller 绑定）；
    * `required_caps/0` —— 键集 == 动作集，值全是 `:any`-kind 的 `%Capability{}`
      （plugin_check check 10/11 的运行时镜像）；
    * `data_owner/1` —— per-instance 收口（`:no_owner`）；
    * `handle_save_creds/2` —— 凭证写盘（沙箱 EZAGENT_HOME）+ 坏参拒收；
    * `handle_bind_pr_sync/2` + `handle_unbind_pr_sync/2` —— 薄包 PrSync.bind/unbind，
      bind/unbind 幂等 + 缺参显式拒收（本插件监督树下真起停 poller，不打真网）。

  出站 handler（create_issue/post_comment/…）调真 `gh` CLI，归 live e2e，本文件不覆。
  """
  use ExUnit.Case, async: false

  alias Ezagent.Behavior.Github
  alias Ezagent.Capability
  alias EzagentPluginGithub.Creds

  @actions [
    :create_issue,
    :post_comment,
    :get_pull,
    :create_commit_status,
    :list_open_prs,
    :save_creds,
    :bind_pr_sync,
    :unbind_pr_sync
  ]

  test "actions/0 声明 8 个网关动作（6 出站 + 2 入站 poller 绑定）" do
    assert MapSet.new(Github.actions()) == MapSet.new(@actions)
    assert length(Github.actions()) == 8
  end

  test "required_caps/0 键集 == 动作集，值全是 :any-kind 的 %Capability{}" do
    caps = Github.required_caps()

    assert MapSet.new(Map.keys(caps)) == MapSet.new(@actions)

    assert Enum.all?(caps, fn {action, cap} ->
             match?(%Capability{kind: :any, behavior: Github, action: ^action}, cap)
           end)
  end

  test "data_owner/1 → :no_owner（per-instance 收口）" do
    assert Github.data_owner(%{}) == :no_owner
    assert Github.data_owner(:anything) == :no_owner
  end

  describe "handle_save_creds/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "esr-ghbe-#{System.unique_integer([:positive])}")
      System.put_env("EZAGENT_HOME", tmp)
      System.put_env("EZAGENT_PROFILE", "default")

      on_exit(fn ->
        System.delete_env("EZAGENT_HOME")
        System.delete_env("EZAGENT_PROFILE")
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "写凭证 → {:ok, %{}, []} + Creds 可回读" do
      assert {:ok, %{}, []} =
               Github.handle_save_creds(%{access_token: "ghp_x", repo: "o/r"}, %{})

      assert {:ok, %{token: "ghp_x", repo: "o/r"}} = Creds.read()
    end

    test "缺/坏 access_token → {:error, :access_token_required}" do
      assert {:error, :access_token_required} = Github.handle_save_creds(%{repo: "o/r"}, %{})

      assert {:error, :access_token_required} =
               Github.handle_save_creds(%{access_token: 123}, %{})
    end
  end

  describe "handle_bind_pr_sync/2 + handle_unbind_pr_sync/2（入站 poller 绑定，本插件监督树）" do
    test "bind 起 poller（幂等）→ unbind 停（幂等）" do
      # 真 canonical entity:// 看板实例 URI（生产传的就是它；gateway 经 Ezagent.URI.new! 还原，
      # new! 校验 3seg + registered scheme，非 URI 串会 raise——必须真 URI）。
      kanban = "entity://system/agent/kanban-be-#{System.unique_integer([:positive])}"

      assert {:ok, %{}, []} = Github.handle_bind_pr_sync(%{kanban_uri: kanban, repo: "o/r"}, %{})
      # 再 bind 同板 → 幂等成功（已在轮询）。
      assert {:ok, %{}, []} = Github.handle_bind_pr_sync(%{kanban_uri: kanban, repo: "o/r"}, %{})

      assert {:ok, %{}, []} = Github.handle_unbind_pr_sync(%{kanban_uri: kanban}, %{})
      # unbind 不在的板 → 幂等成功（无可停的也算已停，非静默丢）。
      assert {:ok, %{}, []} = Github.handle_unbind_pr_sync(%{kanban_uri: kanban}, %{})
    end

    test "缺参 → 显式错误（非静默）" do
      assert {:error, :kanban_uri_and_repo_required} =
               Github.handle_bind_pr_sync(%{repo: "o/r"}, %{})

      assert {:error, :kanban_uri_required} = Github.handle_unbind_pr_sync(%{}, %{})
    end
  end
end
