defmodule EzagentPluginDealScout.Config do
  @moduledoc """
  DealScout 的运行期配置层。

  ## 两类配置，两条存储路径

    * **profile + keywords**（发现流的关键词 / 千人千面匹配数据源）——存进 ActionSet
      的 Lifecycle **state slice**：`set_profile/2` / `set_keywords/2` 返回一个
      `{:set, key, value}` effect（框架写、`ctx[:read]` 读、自动 snapshot），照
      `Ezagent.ActionSet.Kb` 的 `{:set, ...}` idiom（`kb.ex:119,135`）。plugin
      作者永远看不到底层存储。

    * **token**（定向源的登录凭证）——走 core 现成的 `system://credentials/*.yaml`
      凭证 API（`Ezagent.System.FsResolver` + `Ezagent.URI.system/2`），照 kanban
      `EzagentPluginKanban.Github.write_creds/1` / `read_creds/0` 的 sanctioned
      idiom（`github.ex:19-52`）：写 `FsResolver.path!` + `File.write` + `chmod
      0o600`，读 `FsResolver.read_yaml`。每个源一个文件
      `system://credentials/dealscout_<source>.yaml`。**只调 core 公开 API，不改
      core。**

  token 缺失一律 **fail-closed**（`read_token/1` 返回 `:error`），供 `Fetch`
  的定向抓取分支显式跳过 + telemetry（spec §3.2 硬要求 3），不 silent 抓空。
  """

  alias Ezagent.System.FsResolver
  alias Ezagent.URI, as: EzURI

  # 每源一个凭证文件；`system://credentials/<name>` 的 `<name>` 段照 kanban
  # `github.yaml` 先例（`.yaml` 后缀合法、非路径分隔）。
  @creds_type "credentials"
  @creds_prefix "dealscout_"

  # --- profile / keywords → state slice effect --------------------------------

  @doc "设 profile —— 返回写入 Lifecycle state slice 的 `{:set, key, value}` effect（key=`:profile`）。"
  @spec set_profile(map(), map()) :: {:set, :profile, map()}
  def set_profile(_current, profile) when is_map(profile), do: {:set, :profile, profile}

  @doc "设关键词 —— 返回 `{:set, key, value}` slice effect（key=`:keywords`）。"
  @spec set_keywords(map(), [String.t()]) :: {:set, :keywords, [String.t()]}
  def set_keywords(_current, keywords) when is_list(keywords), do: {:set, :keywords, keywords}

  @doc """
  pin 一个爬取批次 —— 返回 `{:set, key, value}` slice effect（key=`:pinned_batches`，去重）。被 pin
  的批次即使超期也被 `RetentionSweeper.prune/2` 保留（成员限定：改自己那份配置需持
  config cap，匿名 / 房外人无此 cap，spec §6）。
  """
  @spec pin_batch(map(), String.t()) :: {:set, :pinned_batches, [String.t()]}
  def pin_batch(current, batch_id) when is_binary(batch_id) do
    pinned = Map.get(current, :pinned_batches, [])
    {:set, :pinned_batches, Enum.uniq([batch_id | pinned])}
  end

  # --- token → system://credentials/dealscout_<source>.yaml -------------------

  @doc """
  写某定向源的 token 到 `system://credentials/dealscout_<source>.yaml`（admin-gated
  文件层，照 kanban `Github.write_creds/1`：`path!` + `File.write` + `chmod 0o600`）。
  """
  @spec write_token(String.t(), String.t()) :: :ok | {:error, term()}
  def write_token(source, token) when is_binary(source) and is_binary(token) and token != "" do
    file = FsResolver.path!(creds_uri(source))
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, "token: \"#{token}\"\n") do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  def write_token(_, _), do: {:error, :invalid_token}

  @doc """
  读某定向源的 token。**fail-closed**：文件不存在 / 无 `token` 键 / 解析失败一律
  返回 `:error`（不返回空串），让抓取侧显式跳过 + telemetry。
  """
  @spec read_token(String.t()) :: {:ok, String.t()} | :error
  def read_token(source) when is_binary(source) do
    case FsResolver.read_yaml(creds_uri(source)) do
      {:ok, %{"token" => t}} when is_binary(t) and t != "" -> {:ok, t}
      _ -> :error
    end
  end

  @doc "删除某源凭证文件（测试清理 / 撤销源用）。缺文件视为已删。"
  @spec delete_token(String.t()) :: :ok
  def delete_token(source) when is_binary(source) do
    _ = File.rm(FsResolver.path!(creds_uri(source)))
    :ok
  end

  defp creds_uri(source), do: EzURI.system(@creds_type, @creds_prefix <> source <> ".yaml")
end
