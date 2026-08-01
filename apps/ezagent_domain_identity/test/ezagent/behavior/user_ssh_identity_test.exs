defmodule Ezagent.ActionSet.UserSshIdentityTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.UserSshIdentity

  # Lifecycle handler 是纯 (args, ctx) 函数，可直接单测，无需起 Kind 进程。
  # ctx 只需提供 handler 实际用到的键：:self_uri 与 :read。
  defp ctx(state \\ %{}) do
    %{
      self_uri: Ezagent.URI.entity("default", "user", "alice"),
      read: fn key, default -> Map.get(state, key, default) end
    }
  end

  describe "generate_ssh_key" do
    test "生成密钥对，返回公钥与指纹，且不返回私钥" do
      assert {:ok, result, effects} =
               UserSshIdentity.handle_generate_ssh_key(%{comment: "alice@ezagent"}, ctx())

      assert String.starts_with?(result.public_key, "ssh-ed25519 ")
      assert is_binary(result.fingerprint) and result.fingerprint != ""
      refute Map.has_key?(result, :private_key)

      # 私钥必须进 state
      private =
        Enum.find_value(effects, fn
          {:set, :private_key, v} -> v
          _ -> nil
        end)

      assert String.starts_with?(private, "-----BEGIN OPENSSH PRIVATE KEY-----")

      # 审计
      assert Enum.any?(effects, &match?({:emit, :ssh_identity_generated, _}, &1))
    end

    test "已存在身份时拒绝，不覆盖" do
      state = %{public_key: "ssh-ed25519 AAAA existing", private_key: "existing"}

      assert {:error, :ssh_identity_exists} =
               UserSshIdentity.handle_generate_ssh_key(%{}, ctx(state))
    end

    test "生成后临时目录不残留" do
      before = tmp_entries()
      assert {:ok, _r, _e} = UserSshIdentity.handle_generate_ssh_key(%{}, ctx())
      assert tmp_entries() == before
    end

    # 任务 1a 补充（dispatcher 要求）: keygen/1 同时有 rescue 与 catch 子句;
    # System.cmd/3 在可执行文件缺失时经 `:erlang.error(:enoent, ...)` 抛出
    # 原始 :error，Exception.normalize/3 把它包成 ErlangError（没有专属
    # Elixir 异常可对应），因此会被 `rescue e in [File.Error, ErlangError]`
    # 接住——不会走到 `catch :error, :enoent`。用 PATH 清空来复现"可执行
    # 文件缺失"，断言最终仍是 `{:error, {:keygen_failed, _}}`，不会 crash。
    # 手法与 apps/ezagent_domain_python/test/spec_test.exs 的
    # ":uv_script returns {:error, :uv_not_found} when PATH lacks uv" 同构。
    test "ssh-keygen 缺失时返回 keygen_failed，不 crash" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

      try do
        assert {:error, {:keygen_failed, _reason}} =
                 UserSshIdentity.handle_generate_ssh_key(%{}, ctx())
      after
        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end
    end
  end

  defp tmp_entries do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ezagent-sshkeygen-"))
    |> Enum.sort()
  end
end
