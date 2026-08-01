defmodule Ezagent.ActionSet.UserSshIdentityTest do
  # M3: this module mutates process-global state in several tests
  # (System.put_env("PATH", ...) for the missing-binary path;
  # Application.put_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms, _)
  # for the timeout path) — async: true would race any other async test
  # module shelling out or reading that same application env concurrently.
  # Cost of serializing this one file is effectively zero.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

      # I4: assert the EXACT key set, not just the absence of :private_key —
      # a regression that renames the field (e.g. private key surfacing
      # under :fingerprint, or tacked onto :public_key) would still pass a
      # bare `refute Map.has_key?(result, :private_key)`.
      assert Map.keys(result) |> Enum.sort() == [:fingerprint, :public_key]

      # 私钥必须进 state
      private =
        Enum.find_value(effects, fn
          {:set, :private_key, v} -> v
          _ -> nil
        end)

      assert String.starts_with?(private, "-----BEGIN OPENSSH PRIVATE KEY-----")

      # I4: the raw private key bytes must not appear anywhere in the
      # SERIALIZED return value, not merely absent under a :private_key
      # key. Jason.encode!/1 is what actually crosses the wire to a
      # GUI/CLI consumer.
      refute Jason.encode!(result) =~ private

      # 审计
      assert Enum.any?(effects, &match?({:emit, :ssh_identity_generated, _}, &1))
    end

    # M5: split from one fixture that set BOTH keys at once — that form
    # can't prove either flag is independently sufficient to trip the
    # existence guard. A regression that only checks :public_key (or only
    # :private_key) must fail one of these two, not be masked by the other
    # always being present too.
    test "已存在身份时拒绝，不覆盖 —— 只有 public_key" do
      state = %{public_key: "ssh-ed25519 AAAA existing"}

      assert {:error, :ssh_identity_exists} =
               UserSshIdentity.handle_generate_ssh_key(%{}, ctx(state))
    end

    test "已存在身份时拒绝，不覆盖 —— 只有 private_key" do
      state = %{private_key: "existing-private"}

      assert {:error, :ssh_identity_exists} =
               UserSshIdentity.handle_generate_ssh_key(%{}, ctx(state))
    end

    test "生成后临时目录不残留" do
      before = tmp_entries()
      assert {:ok, _r, _e} = UserSshIdentity.handle_generate_ssh_key(%{}, ctx())
      assert tmp_entries() == before
    end

    # I1: a comment containing a newline lets ssh-keygen write a SECOND,
    # attacker-chosen line into the .pub file — a syntactically valid
    # authorized_keys entry riding along with the real key, uncovered by
    # fingerprint/1 (which only ever inspects the first line). Reviewer
    # reproduced this against the pre-fix code; must be rejected before
    # ssh-keygen ever runs.
    test "comment 含换行时拒绝，不调用 ssh-keygen（I1 注入防护）" do
      before = tmp_entries()
      malicious = "me@x\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB evil@attacker"

      assert {:error, :invalid_comment} =
               UserSshIdentity.handle_generate_ssh_key(%{comment: malicious}, ctx())

      # Never got as far as creating a tmp dir — validation runs first.
      assert tmp_entries() == before
    end

    test "comment 含 CR 时同样拒绝" do
      assert {:error, :invalid_comment} =
               UserSshIdentity.handle_generate_ssh_key(%{comment: "a\rb"}, ctx())
    end

    # 任务 1a 补充（dispatcher 要求）: System.cmd/3 在可执行文件缺失时经
    # `:erlang.error(:enoent, ...)` 抛出原始 :error，Exception.normalize/3
    # 把它包成 ErlangError（没有专属 Elixir 异常可对应）。这个 rescue 现在
    # 挪到了 run_ssh_keygen/2 的 Task 内部——挪之前若未捕获，抛出会经
    # Task.async 的 link 把调用进程也拖死（实测确认，见 run_ssh_keygen/2
    # 注释），比 I2 要修的"卡死"更糟。用 PATH 清空复现"可执行文件缺失"，
    # 断言最终仍是 `{:error, {:keygen_failed, _}}`，不会 crash，且不留
    # tmp 目录(M4)。手法与 apps/ezagent_domain_python/test/spec_test.exs 的
    # ":uv_script returns {:error, :uv_not_found} when PATH lacks uv" 同构。
    test "ssh-keygen 缺失时返回 keygen_failed，不 crash，且不留 tmp 目录" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")
      before = tmp_entries()

      try do
        assert {:error, {:keygen_failed, _reason}} =
                 UserSshIdentity.handle_generate_ssh_key(%{}, ctx())

        # M4: the existing missing-binary regression only asserted the
        # error shape — it never checked whether the tmp dir it created
        # (mkdir_p! succeeds even though ssh-keygen then fails) got cleaned
        # up. The error path is exactly where a leak is most likely.
        assert tmp_entries() == before
      after
        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end
    end

    # I2: System.cmd has no timeout — a stuck ssh-keygen would otherwise
    # block this User's GenServer forever. Inject an unreachably small
    # timeout via the module's Application-env override seam so a REAL,
    # fast ssh-keygen invocation still exceeds it, proving the timeout path
    # returns an error (and logs) instead of hanging.
    test "ssh-keygen 超过时限时返回 timeout，不挂住，且不留 tmp 目录（I2）" do
      Application.put_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms, 0)
      before = tmp_entries()

      try do
        log =
          capture_log(fn ->
            assert {:error, {:keygen_failed, :timeout}} =
                     UserSshIdentity.handle_generate_ssh_key(%{}, ctx())
          end)

        assert log =~ "ssh-keygen exceeded"

        # keygen/1's `after` covers every branch of the inner case,
        # including this one — no tmp-dir leak even though the underlying
        # OS process itself may be left orphaned (accepted tradeoff, I2).
        assert tmp_entries() == before
      after
        Application.delete_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms)
      end
    end

    # M1: a cleanup failure must be logged, not silently discarded — it
    # leaves a plaintext private key sitting in /tmp. Exercises
    # cleanup_tmp_dir/1 directly (the `@doc false` seam extracted from
    # keygen/1's `after` block) against a directory THIS test fully
    # controls — keygen/1's own tmp dir name is randomized internally and
    # can't be raced from the outside to force a real rm_rf failure.
    test "M1: 清理失败时记日志，不静默" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ezagent-sshkeygen-cleanup-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "stuck"), "x")
      # Deleting a file requires write permission on its CONTAINING
      # directory, not the file itself — stripping write from `dir` makes
      # the file inside un-removable, deterministically forcing
      # File.rm_rf/1 to fail. (Non-root only; this suite doesn't run as
      # root — root ignores the permission bit entirely.)
      File.chmod!(dir, 0o500)

      try do
        log =
          capture_log(fn ->
            assert :ok = UserSshIdentity.cleanup_tmp_dir(dir)
          end)

        assert log =~ "failed to remove ssh-keygen tmp dir"
      after
        File.chmod(dir, 0o700)
        File.rm_rf(dir)
      end
    end
  end

  # M2: fingerprint/1 must FAIL on unparseable input, not persist a
  # "SHA256:unknown" placeholder a downstream reader could mistake for a
  # real value. Exercised directly (real ssh-keygen output is always
  # well-formed, so the malformed-input branch can't be reached through
  # handle_generate_ssh_key/2 without mocking the subprocess).
  describe "fingerprint/1 (M2)" do
    test "valid pubkey line returns {:ok, \"SHA256:\" <> _}" do
      line = "ssh-ed25519 " <> Base.encode64("fake-key-bytes-for-this-test")

      assert {:ok, fp} = UserSshIdentity.fingerprint(line)
      assert String.starts_with?(fp, "SHA256:")
    end

    test "line with no base64 segment returns :error, not a placeholder" do
      assert :error = UserSshIdentity.fingerprint("not-a-valid-key-line")
    end

    test "line whose second segment isn't valid base64 returns :error" do
      assert :error = UserSshIdentity.fingerprint("ssh-ed25519 not-base64!!!")
    end
  end

  defp tmp_entries do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ezagent-sshkeygen-"))
    |> Enum.sort()
  end
end
