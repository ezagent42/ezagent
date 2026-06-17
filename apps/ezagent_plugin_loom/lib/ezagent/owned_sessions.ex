defmodule Ezagent.PluginLoom.OwnedSessions do
  @moduledoc """
  Loom **临时用户升级 → 账号拥有会话**(2026-06-17)。

  发布链接进来的匿名访客在临时用户 `loomui_<sid>` 下聊天。注册/登录后,正式账号
  「接管」这个会话:join 进 session(成员 = 拥有权)+ 把那段 **Salesperson 对话历史**
  快照一份到这里,按**账号** key。底层 session 发言记录(`messages` 表)**不动** ——
  不碰 core,临时用户与它发过的消息原样保留。

  旁路 JSON:`~/.ezagent/<profile>/loom_owned.json`,key = 账号 URI →

      [ %{ "ws", "sid", "conversation" => [%{"role","text"}, ...], "migrated_at" } , ... ]

  > 命名:这是 loom 自己的「账号拥有的会话 + 对话快照」,**不要**跟 ezagent 的 session
  > ownership / Kind 持久化混。
  """

  @max_per_account 200

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_owned.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_all(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
    :ok
  end

  @doc """
  正式账号接管 `(ws, sid)` 会话:记下「账号拥有此会话」+ 当前对话快照(按 `{ws,sid}` 去重
  upsert,新的在前)。`conversation` = `salesperson_conversation` 重建出来的那段。
  """
  @spec claim(String.t(), String.t(), String.t(), list()) :: :ok
  def claim(account_uri, ws, sid, conversation)
      when is_binary(account_uri) and account_uri != "" and is_binary(ws) and is_binary(sid) do
    convo = if is_list(conversation), do: conversation, else: []

    entry = %{
      "ws" => ws,
      "sid" => sid,
      "conversation" => convo,
      "migrated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    all = load_all()
    existing = all |> Map.get(account_uri, []) |> List.wrap()
    deduped = Enum.reject(existing, fn e -> is_map(e) and e["ws"] == ws and e["sid"] == sid end)
    updated = [entry | deduped] |> Enum.take(@max_per_account)

    all |> Map.put(account_uri, updated) |> save_all()
  rescue
    _ -> :ok
  end

  def claim(_, _, _, _), do: :ok

  @doc "某账号拥有的全部会话(新的在前)。供「我的会话」/ 跨设备找回用。"
  @spec for_account(String.t()) :: [map()]
  def for_account(account_uri) when is_binary(account_uri) and account_uri != "" do
    load_all() |> Map.get(account_uri, []) |> List.wrap()
  rescue
    _ -> []
  end

  def for_account(_), do: []
end
