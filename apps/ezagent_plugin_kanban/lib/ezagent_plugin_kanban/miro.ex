defmodule EzagentPluginKanban.Miro do
  @moduledoc """
  Miro REST 客户端（df-prd 增量 4 出站）—— ezagent 把节点树推到 Miro 板。

  用 `:httpc` + `Jason`（对齐 `EzagentPluginFeishu.Client`，不引重依赖）。凭证从
  `system://credentials/miro.yaml` 读（`access_token` 必填、`board_id` 可选）。

  ## API 契约（已对真实 experimental 端点探活核实，2026-06-22）

  - 建板：`POST /v2/boards` body `%{name: ...}` → `%{"id" => board_id}`
  - 建节点：`POST /v2-experimental/boards/{board}/kanban_nodes`
    body `%{data: %{nodeView: %{data: %{content: text}}}}`；**第一个自动成根**。
    子节点加 `%{parent: %{id: parent_miro_id}}`。
  - 读节点：`GET /v2-experimental/boards/{board}/kanban_nodes` → `%{"data" => [...]}`

  ⚠️ mind-map 节点端点是 Miro 标注的 **experimental**，行为可能变。
  """

  @api "https://api.miro.com"

  @typedoc "Miro 节点 id（字符串）"
  @type miro_id :: String.t()

  @doc "从 miro.yaml 读凭证。返回 `{:ok, %{token, board_id}}`（board_id 可能 nil）。"
  @spec read_creds() :: {:ok, %{token: String.t(), board_id: String.t() | nil}} | {:error, term()}
  def read_creds do
    # 运行时从段构造（sanctioned，过 uri_query.scan）；不在模块属性建——编译期
    # SchemeRegistry 还没注册，`URI.new!` 会崩。
    case Ezagent.System.FsResolver.read_yaml(Ezagent.URI.system("credentials", "miro.yaml")) do
      {:ok, %{"access_token" => token} = m} when is_binary(token) and token != "" ->
        {:ok, %{token: token, board_id: blank_to_nil(Map.get(m, "board_id"))}}

      {:ok, _} ->
        {:error, :miro_access_token_missing}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  写 Miro 凭证到 `system://credentials/miro.yaml`（照 `Ezagent.AgentBridge.TokenStore`
  的 sanctioned idiom：`FsResolver.path!` 解析受保护路径 → `File.write` → `chmod 0o600`）。
  供 world 的 kanban 配置页 UI 保存（admin-gated）。
  """
  @spec write_creds(%{
          required(:access_token) => String.t(),
          optional(:board_id) => String.t() | nil
        }) ::
          :ok | {:error, term()}
  def write_creds(%{access_token: token} = creds) when is_binary(token) and token != "" do
    board = blank_to_nil(Map.get(creds, :board_id))

    body =
      "access_token: \"#{token}\"\n" <>
        if(board, do: "board_id: \"#{board}\"\n", else: "")

    file = Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "miro.yaml"))
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, body) do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  def write_creds(_), do: {:error, :access_token_required}

  @doc "建一块新板，返回 `{:ok, board_id}`。"
  @spec create_board(String.t(), String.t()) :: {:ok, miro_id()} | {:error, term()}
  def create_board(token, name) do
    case post(token, "/v2/boards", %{name: name}) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  在板上建一个 mind-map 节点。`parent_miro_id=nil` 建根（板上第一个节点）；
  非 nil 则建为该父节点的子节点。返回 `{:ok, miro_node_id}`。
  """
  @spec create_node(String.t(), miro_id(), String.t(), miro_id() | nil) ::
          {:ok, miro_id()} | {:error, term()}
  def create_node(token, board_id, content, parent_miro_id \\ nil) do
    body = %{data: %{nodeView: %{data: %{content: content}}}}
    body = if parent_miro_id, do: Map.put(body, :parent, %{id: parent_miro_id}), else: body

    case post(token, "/v2-experimental/boards/#{board_id}/kanban_nodes", body) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc "读板上所有 mind-map 节点，返回 `{:ok, [node_map]}`。"
  @spec get_nodes(String.t(), miro_id()) :: {:ok, [map()]} | {:error, term()}
  def get_nodes(token, board_id) do
    case get(token, "/v2-experimental/boards/#{board_id}/kanban_nodes") do
      {:ok, %{"data" => nodes}} when is_list(nodes) -> {:ok, nodes}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  删一个 mind-map 节点（experimental 端点，实测 204）。Miro 无 in-place update，
  改名/移动靠 delete+create——这是增量同步的基础。
  """
  @spec delete_node(String.t(), miro_id(), miro_id()) :: :ok | {:error, term()}
  def delete_node(token, board_id, miro_id) do
    case delete(token, "/v2-experimental/boards/#{board_id}/kanban_nodes/#{miro_id}") do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "删整块 Miro 板（ezagent 删 kanban 时联动拆镜像）。"
  @spec delete_board(String.t(), miro_id()) :: :ok | {:error, term()}
  def delete_board(token, board_id), do: delete(token, "/v2/boards/#{board_id}")

  @doc "删板上所有 mind-map 节点（复用同板前先清空）。"
  @spec delete_all_nodes(String.t(), miro_id()) :: :ok | {:error, term()}
  def delete_all_nodes(token, board_id) do
    with {:ok, nodes} <- get_nodes(token, board_id) do
      Enum.reduce_while(nodes, :ok, fn %{"id" => id}, _ ->
        case delete_node(token, board_id, id) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  # --- :httpc helpers（对齐 feishu client）---------------------------------

  # `{:body_format, :binary}`：让 :httpc 把 body 返成 binary，不是 charlist——
  # 否则 to_string(字节列表) 会把每字节当码点再编码一遍 = UTF-8 双重编码（中文乱码）。
  @http_opts [{:body_format, :binary}]
  @http_http_opts [{:timeout, 30_000}, {:connect_timeout, 15_000}]

  defp post(token, path, payload) do
    body = Jason.encode!(payload)
    request = {String.to_charlist(@api <> path), auth_headers(token), ~c"application/json", body}

    case :httpc.request(:post, request, @http_http_opts, @http_opts) do
      {:ok, {{_, code, _}, _, resp}} when code in [200, 201] ->
        Jason.decode(resp)

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, {:http_status, code, resp}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp get(token, path) do
    request = {String.to_charlist(@api <> path), auth_headers(token)}

    case :httpc.request(:get, request, @http_http_opts, @http_opts) do
      {:ok, {{_, 200, _}, _, resp}} ->
        Jason.decode(resp)

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, {:http_status, code, resp}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp delete(token, path) do
    request = {String.to_charlist(@api <> path), auth_headers(token)}

    case :httpc.request(:delete, request, @http_http_opts, []) do
      # 404 也算成功：删除是幂等的，节点已不在 = 已达目标状态（父节点删除会
      # 级联删子节点，随后再删那个子节点就会 404）。
      {:ok, {{_, code, _}, _, _}} when code in [200, 204, 404] ->
        :ok

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, {:http_status, code, to_string(resp)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp auth_headers(token) do
    [{~c"Authorization", String.to_charlist("Bearer " <> token)}]
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
