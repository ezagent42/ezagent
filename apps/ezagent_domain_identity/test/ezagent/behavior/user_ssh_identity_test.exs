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

  # C7: a REAL, parseable ed25519 OpenSSH private key (generated once via
  # `ssh-keygen -t ed25519`, embedded as a fixture) — NOT the earlier
  # `header <> "x"` placeholder. That placeholder made "starts with the
  # right header" look like a sufficient validity check when it never
  # actually exercised anything parseable — a truncated/corrupted real key
  # is a materially different shape than a hand-typed fake one. Throwaway
  # test-only key, unrelated to any real host or account.
  @real_private_key """
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
  QyNTUxOQAAACBFs0FwGXChjFi1JEbjGXn96L/9h0IfAcyzSz72LG3mCwAAAJj1/+AZ9f/g
  GQAAAAtzc2gtZWQyNTUxOQAAACBFs0FwGXChjFi1JEbjGXn96L/9h0IfAcyzSz72LG3mCw
  AAAEAZZGbQeyRg9BLQ/ocC1dCTSQwvWKdwWOhoYmA9jrY7GkWzQXAZcKGMWLUkRuMZef3o
  v/2HQh8BzLNLPvYsbeYLAAAAFHRlc3QtZml4dHVyZUBlemFnZW50AQ==
  -----END OPENSSH PRIVATE KEY-----
  """

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

      # R1 (round-2 review): the I4 fix above — asserting against
      # Jason.encode!(result) — PROVES NOTHING. OpenSSH private keys
      # contain literal newlines; Jason.encode!/1 JSON-escapes every `\n`
      # to the two-character sequence `\`+`n`, so the raw key's byte
      # sequence is NEVER a substring of the encoded JSON, even when a
      # field genuinely carries the private key verbatim. Both regressions
      # this assertion is meant to catch (private key smuggled into
      # :public_key or :fingerprint) were independently reproduced by two
      # reviewers and PASSED the old `refute Jason.encode!(result) =~
      # private` — verified directly: reverting the assertion below to
      # that Jason.encode!/1-based form and re-running reproduces both
      # false-negatives (a smuggled private key in either field still
      # passes). Assert against the RAW map values instead — no
      # serialization step to hide behind.
      refute Enum.any?(Map.values(result), &(is_binary(&1) and String.contains?(&1, private)))

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

    # R1: metadata-only state (no public_key, no
    # private_key — e.g. fingerprint/comment/created_at surviving a snapshot
    # migration or partial repair) is a genuinely reachable "identity
    # exists" shape per any_identity_field?/1 — the SAME predicate
    # identity_state/1, public_key_state/1, and handle_revoke_ssh_key/2 use.
    # Before this fix, handle_generate_ssh_key/2 used its own two-field
    # check (public_key || private_key) and would silently proceed here,
    # contradicting its own `description` ("Refuses when an identity
    # already exists; revoke first.") and contradicting :read_ssh_key /
    # :revoke_ssh_key, which both already treat this shape as identity
    # present.
    test "已存在身份时拒绝，不覆盖 —— 只有 metadata 字段(无 public_key/private_key)" do
      state = %{fingerprint: "SHA256:abc", comment: "alice", created_at: DateTime.utc_now()}

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

    # R2 (round-2 review): verified empirically (elixir -e probe against
    # this OTP 28 pair, see user_ssh_identity.ex's validate_comment/1
    # comment) that System.cmd/3 does NOT raise for a NUL-containing argv
    # element here — it silently truncates the argument at the NUL before
    # exec. Pre-fix, `handle_generate_ssh_key/2` would therefore SUCCEED
    # with a comment of `"a\0b"`, persisting that full string via the
    # `{:set, :comment, _}` effect while the actual generated key's
    # embedded comment (what ssh-keygen wrote to the .pub file) is only
    # `"a"` — a silent mismatch between persisted state and the real key
    # contents. Must be rejected before ssh-keygen ever runs, same as
    # `\n`/`\r`.
    test "comment 含 NUL 时同样拒绝（R2）" do
      before = tmp_entries()

      assert {:error, :invalid_comment} =
               UserSshIdentity.handle_generate_ssh_key(%{comment: "a\0b"}, ctx())

      assert tmp_entries() == before
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

  describe "read_ssh_public_key" do
    test "返回公钥与指纹" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"}

      assert {:ok, %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"} = result,
              []} = UserSshIdentity.handle_read_ssh_public_key(%{}, ctx(state))

      # O1: assert the EXACT key set (same technique as I4, line 35) — Elixir
      # map patterns are PARTIAL matches, so the assert above alone would
      # still pass if the handler tacked extra keys (e.g. :private_key) onto
      # the result, silently handing a low-sensitivity public-read cap
      # holder the private key.
      assert Map.keys(result) |> Enum.sort() == [:fingerprint, :public_key]
    end

    test "无身份时 absent" do
      assert {:error, :ssh_identity_absent} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx())
    end

    # C3: private_key present but public_key missing (partial write) must NOT
    # be misreported as "no identity" — the identity DOES exist, just not in
    # the shape this read needs.
    test "私钥存在但公钥缺失时 unavailable，不是 absent" do
      state = %{private_key: @real_private_key}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx(state))
    end

    # C3: public_key present but fingerprint missing must NOT silently return
    # a result with `fingerprint: nil` — that would violate this action's own
    # `returns: %{fingerprint: :string}` declaration.
    test "公钥存在但指纹缺失时 unavailable，不违反 returns 声明" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx(state))
    end

    # m3 (final-review Minor): an empty-string public_key (partial write)
    # must NOT report success — is_binary("") is true, so without the
    # `pub != ""` guard this would return {:ok, %{public_key: "", ...}},
    # and 1b would paste an empty public key to the provider. The
    # private-key side already guards equivalently via
    # valid_private_key?/1's header check.
    test "公钥为空字符串时 unavailable，不是成功（m3）" do
      state = %{public_key: "", fingerprint: "SHA256:abc"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx(state))
    end
  end

  describe "read_ssh_key" do
    test "返回私钥并留审计" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: @real_private_key,
        fingerprint: "SHA256:abc"
      }

      assert {:ok, result, effects} = UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))

      # C6: assert the returned private key is BYTE-EXACT the one placed in
      # state, not merely "some string starting with the OpenSSH header" — a
      # handler returning a DIFFERENT key sharing that header (e.g. another
      # user's) would still pass a bare starts_with? check.
      assert result.private_key == @real_private_key

      # O1: assert the EXACT key set (same technique as I4, line 35).
      assert Map.keys(result) |> Enum.sort() == [:private_key]

      # C8: the audit emit must carry the RIGHT user_uri and a real
      # timestamp, not just exist — "谁在什么时候取走了私钥" is the entire
      # reason this emit exists; `match?(..., _)` alone would still pass with
      # an empty/wrong payload.
      assert {:emit, :ssh_identity_read, payload} =
               Enum.find(effects, &match?({:emit, :ssh_identity_read, _}, &1))

      assert payload.user_uri == URI.to_string(ctx(state).self_uri)
      assert %DateTime{} = payload.at
    end

    test "无身份时 absent" do
      assert {:error, :ssh_identity_absent} = UserSshIdentity.handle_read_ssh_key(%{}, ctx())
    end

    test "有公钥但私钥缺失时 unavailable —— 绝不降级成 absent" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))
    end

    test "私钥形状不合法时 unavailable" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", private_key: "not-a-key"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))
    end

    # C1: a state carrying ONLY metadata (fingerprint/created_at — no
    # public_key, no private_key) is a genuinely reachable shape (migration
    # leftover, partial restore — the snapshot reload path merges a plain map
    # with no field-combination validation). It must classify as
    # :unavailable ("there WAS an identity record"), never silently downgrade
    # to :absent ("nothing configured") — spec §5.1's precise absent
    # definition ("state 中无任何身份字段").
    test "只有 metadata 字段(无 public_key/private_key)时 unavailable，不降级成 absent" do
      state = %{fingerprint: "SHA256:abc", created_at: DateTime.utc_now()}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))
    end
  end

  describe "revoke_ssh_key" do
    test "清除全部身份字段并留审计" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: @real_private_key,
        fingerprint: "SHA256:abc",
        comment: "alice",
        created_at: DateTime.utc_now()
      }

      assert {:ok, %{revoked: true}, effects} =
               UserSshIdentity.handle_revoke_ssh_key(%{}, ctx(state))

      for key <- [:public_key, :private_key, :fingerprint, :comment, :created_at] do
        assert Enum.any?(effects, &match?({:set, ^key, nil}, &1)),
               "revoke 必须清除 #{key}"
      end

      # C8: the audit emit must carry the RIGHT user_uri and a real
      # timestamp, not just exist.
      assert {:emit, :ssh_identity_revoked, payload} =
               Enum.find(effects, &match?({:emit, :ssh_identity_revoked, _}, &1))

      assert payload.user_uri == URI.to_string(ctx(state).self_uri)
      assert %DateTime{} = payload.at
    end

    test "无身份时幂等返回 revoked: false" do
      assert {:ok, %{revoked: false}, []} = UserSshIdentity.handle_revoke_ssh_key(%{}, ctx())
    end

    # C4: a state carrying ONLY metadata (no public_key, no private_key) must
    # still be revocable — the old guard (`public_key || private_key`)
    # ignored fingerprint/comment/created_at entirely, so this shape could
    # never be cleared by the user: revoke silently reported "nothing to
    # revoke" (revoked: false, no effects) and left the metadata sitting in
    # state forever.
    test "只有 metadata 字段(无 public_key/private_key)时也能撤销" do
      state = %{fingerprint: "SHA256:abc", comment: "alice", created_at: DateTime.utc_now()}

      assert {:ok, %{revoked: true}, effects} =
               UserSshIdentity.handle_revoke_ssh_key(%{}, ctx(state))

      for key <- [:public_key, :private_key, :fingerprint, :comment, :created_at] do
        assert Enum.any?(effects, &match?({:set, ^key, nil}, &1)),
               "revoke 必须清除 #{key}"
      end
    end

    # spec §8 明确要求：revoke 之后 read 必须得 :absent 而非 :unavailable。
    # 这是 revoke 必须清除**全部**身份字段（而非只清私钥）的原因 —— 只清
    # 私钥会留下"有公钥无私钥"的形状，正好落进 :unavailable。
    #
    # C5: fixture 补齐全部 5 个身份字段(含 comment/created_at)，与上面"清除
    # 全部身份字段"测试用的同一份完整 fixture一致——不要用一份本来就不完整
    # 的 state 去验证"清除是否完整"这件事（一份缺 comment/created_at 的
    # 前置 state 无法证明 revoke 真的清了这两个字段，即便它们本就不在其中
    # 因而"看起来"被清了）。
    test "revoke 之后 read 得 absent 而非 unavailable" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: @real_private_key,
        fingerprint: "SHA256:abc",
        comment: "alice",
        created_at: DateTime.utc_now()
      }

      assert {:ok, %{revoked: true}, effects} =
               UserSshIdentity.handle_revoke_ssh_key(%{}, ctx(state))

      # 把 revoke 的 {:set, k, nil} 应用回 state，模拟框架 commit 后的样子
      after_state =
        Enum.reduce(effects, state, fn
          {:set, k, v}, acc -> Map.put(acc, k, v)
          _, acc -> acc
        end)

      assert {:error, :ssh_identity_absent} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(after_state))
    end
  end

  defp tmp_entries do
    # R6: derive from the module's own constant instead of repeating the
    # literal — a rename of @keygen_tmp_prefix would otherwise desync
    # silently and this leak check would go blind without ever going red.
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, UserSshIdentity.tmp_prefix()))
    |> Enum.sort()
  end
end
