defmodule EzagentPluginGithub.Creds do
  @moduledoc """
  GitHub 凭证读写。**两层凭证**（T8 per-identity）：

    1. **per-identity（首选）** —— 每个 caller 自己的 PAT，存在它自己 Agent Kind 的
       `:api_keys` slice（provider `"github"`），经 `Ezagent.Behavior.ApiKeys.put_api_key`
       写（cap-gated + data-owner-gated，只本人/授权者能写）。gateway 按 `ctx.caller`
       用 `token_for_caller/1` 选——**token 跟 identity 走，cap 只是「能用 github 工具」**。
    2. **global（fallback）** —— `system://credentials/github.yaml` 的全局单 token，
       caller 没配自己的时落它（保持现有路径不破）。

  ### per-identity 读法（照 `Ezagent.Behavior.CurlAgent` 的 `:api_keys` 读范式）

  `token_for_caller/1` 经 `Ezagent.Kind.get_slice(caller, :api_keys)`（live Kind）读，
  miss 落 `Ezagent.SnapshotStore.latest/1` 快照兜底——与 curl 读 source agent 的
  `:api_keys` slice 同一 sanctioned 路（非 dispatch、非写、只读自己/调用者的 slice）。
  写侧的 data-owner gate 由复用的 `ApiKeys` behavior 在 dispatch step 5.5 收口
  （`api_keys_migration_parity_test.exs` 已覆），本模块**不另造写路径/不另造机制**。

  ### global 读写（`system://credentials/github.yaml`）

  读经 hardened `Ezagent.System.FsResolver`（`system://` seam，过 UriQuery）；写照
  token_store 的 sanctioned idiom（`FsResolver.path!` + `File.mkdir_p` + `File.write` +
  `chmod 0o600`），供配置页 UI 保存（不写死、admin-gated 由调用方把关）。

  凭证可选（Miro 式可配置覆盖）：配了 token → 调 gh 时传 `GH_TOKEN` env 覆盖；没配 →
  `read/0` 返回 `{:error, :github_token_missing}` / `{:error, :not_found}`，gh 走自带 auth。
  """

  # YAML 写盘上限（防超大 token 撑爆，对齐 kanban github.ex）。
  @creds_content_limit 8_192

  # api_keys slice 里 github PAT 的 provider 键（per-identity token 的存放位）。
  @github_provider "github"

  # github.yaml 的 system URI（凭证目录下的固定文件名）。
  defp creds_uri, do: Ezagent.URI.system("credentials", "github.yaml")

  @doc """
  按 caller（identity）选它自己的 github PAT —— gateway 的 per-identity token 选择点。

    * `{:ok, token}` —— caller 在自己 `:api_keys` slice 配了非空 `"github"` token；
    * `:none` —— caller 没配（或 caller 非 entity URI / Kind 无 slice）→ 调用方落全局 fallback。

  读经 `Ezagent.Kind.get_slice(caller, :api_keys)`（live Kind），miss 落 `SnapshotStore`
  快照——照 `Ezagent.Behavior.CurlAgent` 读 source `:api_keys` 的 sanctioned 范式。
  **绝不**把 token 写日志/暴露；返回值由调用方直接喂给 `GH_TOKEN` env。
  """
  @spec token_for_caller(URI.t() | term()) :: {:ok, String.t()} | :none
  def token_for_caller(%URI{} = caller) do
    with {:ok, slice} <- caller_api_keys_slice(caller),
         {:ok, token} <- fetch_github_token(slice) do
      {:ok, token}
    else
      _ -> :none
    end
  end

  def token_for_caller(_), do: :none

  # caller 的 `:api_keys` slice：先 live Kind，miss 落快照（照 curl source_api_keys_slice）。
  defp caller_api_keys_slice(%URI{} = caller) do
    case Ezagent.Kind.get_slice(caller, :api_keys) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      _ -> snapshot_api_keys_slice(caller)
    end
  end

  defp snapshot_api_keys_slice(%URI{} = caller) do
    case Ezagent.SnapshotStore.latest(caller) do
      {:ok, %{state: state}} when is_map(state) ->
        case Map.get(state, :api_keys) do
          slice when is_map(slice) -> {:ok, Ezagent.Kind.normalize_slice_view(slice)}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp fetch_github_token(slice) do
    keys = Map.get(slice, :keys, %{})

    case Map.get(keys, @github_provider) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :none
    end
  end

  @doc """
  从 `github.yaml` 读凭证。

    * `{:ok, %{token, repo}}` —— `access_token` 非空（`repo` 可为 nil）；
    * `{:error, :github_token_missing}` —— 文件在但无有效 `access_token`；
    * `{:error, :not_found}` —— 文件不存在（正常的未配置态）；
    * `{:error, reason}` —— 读/解析失败。
  """
  @spec read() :: {:ok, %{token: String.t(), repo: String.t() | nil}} | {:error, term()}
  def read do
    case Ezagent.System.FsResolver.read_yaml(creds_uri()) do
      {:ok, %{"access_token" => t} = m} when is_binary(t) and t != "" ->
        {:ok, %{token: t, repo: blank_to_nil(Map.get(m, "repo"))}}

      {:ok, _} ->
        {:error, :github_token_missing}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  写凭证到 `system://credentials/github.yaml`（配置页 UI 保存用）。

  `access_token` 必填非空；`repo`（`owner/name`）可选，空串视为未填。
  写后 `chmod 0o600`（仅属主可读）。
  """
  @spec write(%{required(:access_token) => String.t(), optional(:repo) => String.t() | nil}) ::
          :ok | {:error, term()}
  def write(%{access_token: token} = creds) when is_binary(token) and token != "" do
    repo = blank_to_nil(Map.get(creds, :repo))

    body = "access_token: \"#{token}\"\n" <> if(repo, do: "repo: \"#{repo}\"\n", else: "")

    file = Ezagent.System.FsResolver.path!(creds_uri())
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, String.slice(body, 0, @creds_content_limit)) do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  def write(_), do: {:error, :access_token_required}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
