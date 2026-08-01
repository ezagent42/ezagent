defmodule Ezagent.ActionSet.UserSshIdentity do
  @moduledoc """
  User 的 SSH 身份 —— 生成 / 读公钥 / 读私钥 / 撤销。

  与 `Ezagent.ActionSet.UserTokens` 同构：挂 User Kind，四个 action 全部
  `modes: [:call]`(同步返回结果，失败即 `{:error, _}`，无 fire-and-forget
  路径，故不需要 DLQ 兜底)。

  ## 归属

  SSH 身份归 **User**，不归 Agent。agent 是动态物化的，若归 agent 则每物化
  一个就要去 provider 手工加一次公钥 —— 用不了。设计见
  `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md` §2。

  ## 两容器

  `state`(持久):`:public_key` / `:fingerprint` / `:private_key` /
  `:comment` / `:created_at`。
  `transients`:**空** —— 无 PID / port / ETS / 连接需要在 `activate/2`
  重建，故结构上不可能出现 #110/#113/#114 那族 cold-restart bug。

  ## at-rest

  私钥**明文**存进 snapshot，与既有凭据轨一致(`:api_keys` slice 亦然；
  snapshot 层无加密)。这不是判断 SSH 私钥不值得封存，而是遵循 CLAUDE.md
  「不要在功能 PR 内联引入 caps 正确性以外的安全代码」。统一安全轨接手
  at-rest 加密时，**SSH 私钥应排在 api_keys 之前** —— 后果更重(仓库写权限
  vs LLM 花费)。见 spec §6。

  ## 部署契约(无代码强制，故在此显式记录)

  租户隔离靠**不共享部署**:互不信任的租户各自一套 ezagent 部署
  (workspace = 部署单元)。同部署内的多 workspace 仅用于同一 operator 的
  多环境。**SSH key 的隔离依赖这条契约。**
  """

  use Ezagent.Lifecycle

  require Logger

  @keygen_tmp_prefix "ezagent-sshkeygen-"

  # ssh-keygen 正常是毫秒级；给一个远超正常耗时、但仍有限的上限(I2 —— 人类
  # 裁决 2026-08-01)。没有 timeout 的同步 System.cmd 一旦子进程卡死(二进制
  # 被换、文件系统 stall、熵不足)会无限期占住这个 User 的 GenServer。测试
  # 可经 `Application.put_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms,
  # ms)` 注入极小值以确定性触发超时路径,不改动生产默认值。见
  # run_ssh_keygen/2 对孤儿进程取舍的说明。
  @keygen_timeout_ms 5_000

  action(:generate_ssh_key,
    args: %{comment: {:option, :string}},
    returns: %{public_key: :string, fingerprint: :string},
    caps: [{:generate_ssh_key, kind: :user}],
    description:
      "Generate a fresh ed25519 SSH identity for this User. The private " <>
        "key is stored and NEVER returned by this action — use " <>
        ":read_ssh_key (a separate, more sensitive cap) to retrieve it. " <>
        "Refuses when an identity already exists; revoke first.",
    data_owner: :self,
    modes: [:call]
  )

  # 保留 `kind: :user` 轴（宏自动派生会硬编码 `:any`，见 UserCredentials.ex）。
  # 实测(Ezagent.Cap.Verifier.required_cap/4)：declared.kind == :any 时会
  # 用派发目标 Kind 的 type_name/0 替换，本 Behavior 目前只挂 User Kind，
  # 所以功能上跟省略这段等价——但显式写出把「归 User、不归 Agent」的设计
  # 不变式（见 moduledoc）从"当前唯一注册点恰好是 User"这个偶然事实，
  # 变成结构性断言：万一日后有人手滑把这个 Behavior 也注册到 Agent Kind
  # 上（如 ApiKeys/UserTokens 那样跨 domain 注册），显式 kind: :user 会让
  # 持有 User 态 cap 的调用者在 Agent 目标上匹配失败，而不是静默改口
  # 认成 :agent。
  @doc false
  def required_caps do
    %{
      generate_ssh_key: Ezagent.Capability.cap(:user, __MODULE__, :generate_ssh_key)
    }
  end

  # 与 UserCredentials/UserTokens 同构的 ownership 路由：concrete User URI 自持
  # (自服务场景，见 handle_generate_ssh_key)；`:any` 保持 `:any`；其余无主。
  @doc false
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # Handlers
  # =================================================================

  @doc """
  生成一份新的 ed25519 SSH 身份并写入本 User 的 state。

  已存在身份(state 已有 `:private_key` 或 `:public_key`)时拒绝并返回
  `{:error, :ssh_identity_exists}`——不静默覆盖：覆盖会让用户已在 provider
  配好的公钥突然失效且不可回退。返回值只含 `:public_key` / `:fingerprint`；
  私钥只经一条 `:set` effect 写进 state 的 `:private_key` 键，永不出现在
  返回值里(取私钥是 `:read_ssh_key` 的事，另一条更敏感的 cap，Task 2 落地)。
  """
  def handle_generate_ssh_key(args, ctx) when is_map(args) do
    if ctx[:read].(:private_key, nil) || ctx[:read].(:public_key, nil) do
      {:error, :ssh_identity_exists}
    else
      comment = Map.get(args, :comment) || default_comment(ctx)

      case validate_comment(comment) do
        :ok ->
          case keygen(comment) do
            {:ok, %{public_key: pub, private_key: priv, fingerprint: fp}} ->
              now = DateTime.utc_now()

              {:ok, %{public_key: pub, fingerprint: fp},
               [
                 {:set, :public_key, pub},
                 {:set, :private_key, priv},
                 {:set, :fingerprint, fp},
                 {:set, :comment, comment},
                 {:set, :created_at, now},
                 {:emit, :ssh_identity_generated,
                  %{
                    user_uri: uri_to_string(ctx.self_uri),
                    fingerprint: fp,
                    comment: comment,
                    at: now
                  }}
               ]}

            {:error, reason} ->
              {:error, {:keygen_failed, reason}}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  # I1: `comment` reaches `ssh-keygen -C <comment>` verbatim. A newline lets
  # a caller-controlled comment terminate the .pub file's first line early
  # and append a SECOND, syntactically-valid authorized_keys entry chosen by
  # the caller — `fingerprint/1` only ever inspects the first line, so the
  # fingerprint we return and persist would silently not cover the injected
  # key. Reject at the source rather than relying solely on the
  # first-line-only parsing in `keygen/1` (defense in depth — both are
  # cheap and independent; this is argument validation, not a new security
  # mechanism).
  defp validate_comment(comment) do
    if String.contains?(comment, ["\n", "\r"]) do
      {:error, :invalid_comment}
    else
      :ok
    end
  end

  # =================================================================
  # ssh-keygen —— 用 System.cmd 而非 OsProcess，限时用 Task(I2)
  #
  # X/Y：Y 是"用哪个跑子进程"，X 是"这个子进程的风险特征"。ssh-keygen 是
  # 本地 / 无网络 / 输出固定小的命令，没有 GitRunner 要防的网络挂死、大
  # 输出、孤儿进程树那几条，因此不需要 OsProcess 的 pid_file + 输出上限
  # 那一整套。core 内已有先例：stress_metrics.ex:208、pid_file.ex:240 都
  # 用 System.cmd 跑 `ps`。
  #
  # 但"卡死"风险是真实的、跟"慢"无关——二进制被换、文件系统 stall、熵不足
  # 都会让子进程挂着不退出；没有 timeout 的同步 System.cmd 会无限期占住
  # 这个 User 的 GenServer(人类裁决 2026-08-01)。用 Task.async +
  # Task.yield + Task.shutdown 限时；不新建 OsProcess 那套重机制。
  #
  # argv 中只有路径与 `-N ""`(空 passphrase 标志，不是密钥)，无敏感内容，
  # 故 /proc/<pid>/cmdline 世界可读不构成泄漏。
  # =================================================================
  defp keygen(comment) do
    dir = Path.join(System.tmp_dir!(), @keygen_tmp_prefix <> random_suffix())
    key_path = Path.join(dir, "id_ed25519")

    try do
      File.mkdir_p!(dir)

      case run_ssh_keygen(comment, key_path) do
        {:ok, {_out, 0}} ->
          with {:ok, priv} <- File.read(key_path),
               {:ok, pub_raw} <- File.read(key_path <> ".pub") do
            # I1 defense-in-depth: validate_comment/1 already rejects a
            # `\n`/`\r` comment before we ever get here, but only take the
            # FIRST line of the .pub output regardless — a second line
            # (whatever its origin) is never treated as part of this
            # identity's public key.
            pub = first_line(pub_raw)

            case fingerprint(pub) do
              {:ok, fp} ->
                {:ok, %{private_key: priv, public_key: pub, fingerprint: fp}}

              # M2: an unparseable pubkey must FAIL the action, not persist
              # a "SHA256:unknown" placeholder a downstream reader could
              # mistake for a real value.
              :error ->
                {:error, {:fingerprint_unparseable, pub}}
            end
          else
            {:error, posix} -> {:error, {:read_failed, posix}}
          end

        {:ok, {out, status}} ->
          {:error, {:exit_status, status, String.slice(out, 0, 500)}}

        # :timeout / :keygen_exception / :keygen_crashed from
        # run_ssh_keygen/2 pass straight through — handle_generate_ssh_key/2
        # wraps whatever we return here as `{:keygen_failed, reason}`,
        # exactly like every other keygen/1 failure (human decision: reuse
        # the existing error shape, don't grow a new atom hierarchy for
        # :timeout specifically).
        {:error, _reason} = error ->
          error
      end
    rescue
      # File.mkdir_p!/1 is the only raise left in THIS process — the
      # ssh-keygen subprocess call now runs inside run_ssh_keygen/2's Task
      # and is caught there (see its comment for why it must not be allowed
      # to raise across the Task boundary).
      e in [File.Error, ErlangError] -> {:error, {:keygen_exception, Exception.message(e)}}
    after
      # 立刻删，不依赖进程退出或 GC。M1: don't discard the result — a failed
      # cleanup leaves a plaintext private key sitting in /tmp with nobody
      # told.
      cleanup_tmp_dir(dir)
    end
  end

  # Runs ssh-keygen bounded by keygen_timeout_ms/0. Returns:
  #   {:ok, {output, exit_status}}     — completed within the timeout
  #   {:error, :timeout}               — did not complete in time
  #   {:error, {:keygen_exception, _}} — System.cmd raised (e.g. :enoent,
  #                                      ssh-keygen missing from PATH)
  #   {:error, {:keygen_crashed, _}}   — the task exited for any other reason
  #
  # Task.async (not Task.Supervisor.async_nolink) per the human decision.
  # Task.async LINKS the spawned process to this one — so the System.cmd
  # call is wrapped in its OWN try/rescue INSIDE the task. Verified
  # empirically: without that inner rescue, a raise in the task (e.g. the
  # :enoent case below) kills THIS process too via the link before
  # Task.yield ever gets a chance to turn it into a graceful
  # `{:exit, reason}` — which would be strictly worse than the hang I2
  # exists to fix (a crashed User actor vs. one blocked call). Catching
  # inside the task keeps it exiting NORMALLY (carrying an `{:error, _}`
  # value) for every case we can anticipate; the `{:exit, reason}` clause
  # below is a last-resort net for anything else.
  defp run_ssh_keygen(comment, key_path) do
    task =
      Task.async(fn ->
        try do
          {:ok,
           System.cmd(
             "ssh-keygen",
             ["-t", "ed25519", "-N", "", "-C", comment, "-f", key_path],
             stderr_to_stdout: true
           )}
        rescue
          e in [File.Error, ErlangError] -> {:error, {:keygen_exception, Exception.message(e)}}
        end
      end)

    case Task.yield(task, keygen_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:keygen_crashed, reason}}

      nil ->
        # Task.shutdown/2 kills the ELIXIR task process. It does NOT reach
        # into the OS process tree — the ssh-keygen child can be left
        # orphaned (reparented, not reaped) rather than killed. This is a
        # KNOWN, ACCEPTED tradeoff (human decision, I2): a timeout here is
        # an extremely low-probability event (binary swapped, fs stall,
        # entropy starvation), and building OsProcess's pid_file +
        # orphan-reaping machinery to close that gap costs more than the
        # gap is worth. What we must NOT do is stay silent about it — log
        # so an operator can go find and reap a stray ssh-keygen if this
        # ever fires.
        Logger.warning(
          "UserSshIdentity: ssh-keygen exceeded #{keygen_timeout_ms()}ms and was shut " <>
            "down; the underlying OS process may be left orphaned (accepted tradeoff, " <>
            "see run_ssh_keygen/2)",
          key_path: key_path
        )

        {:error, :timeout}
    end
  end

  defp keygen_timeout_ms do
    Application.get_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms, @keygen_timeout_ms)
  end

  # M1: File.rm_rf/1's result was previously discarded — a failed cleanup
  # left a plaintext private key on disk with no signal anywhere. `def` +
  # `@doc false` (not `defp`) purely so the failure path is unit-testable
  # directly, without racing keygen/1's internally-randomized dir name.
  @doc false
  def cleanup_tmp_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _deleted} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "UserSshIdentity: failed to remove ssh-keygen tmp dir #{dir} — plaintext key " <>
            "material may remain on disk",
          path: path,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # First line only (I1 defense-in-depth), trimmed of surrounding
  # whitespace/CR. `trim: true` drops the empty trailing entry a normal
  # `"...\n"` split produces, so `List.first/2` lands on the real content.
  defp first_line(raw) do
    raw
    |> String.split("\n", trim: true)
    |> List.first(raw)
    |> String.trim()
  end

  # OpenSSH 的 SHA256 指纹：对公钥 base64 段解码后取 sha256，再 base64(去
  # padding)。M2: returns :error (not a placeholder string) when the line
  # can't be parsed — see the fingerprint/1 call site in keygen/1. `def` +
  # `@doc false` (not `defp`) so this is unit-testable directly against
  # malformed input a real ssh-keygen invocation can never produce.
  @doc false
  def fingerprint(pub_line) do
    case String.split(pub_line, " ") do
      [_type, b64 | _rest] ->
        case Base.decode64(b64) do
          {:ok, raw} ->
            {:ok, "SHA256:" <> (:crypto.hash(:sha256, raw) |> Base.encode64(padding: false))}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp default_comment(ctx), do: uri_to_string(ctx.self_uri)

  defp random_suffix, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  # 单独的 helper：避免在 map 字面量里内联 URI.to_string(会触发
  # uri_query.scan 的 :uri_string_key 启发式，capbac.md §9 pitfall 7)
  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(other) when is_binary(other), do: other
end
