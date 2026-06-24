defmodule EzagentPluginKanban.Github do
  @moduledoc """
  GitHub REST 客户端（片6 出站）—— 把 kanban 节点出站成 GitHub issue + post CI 评价评论。

  对称 `EzagentPluginKanban.Miro`：`:httpc` + `Jason`，凭证从 `system://credentials/github.yaml`
  读（`access_token` 必填、`repo`=`owner/name` 必填）；写凭证照 token_store 的 sanctioned idiom
  （`FsResolver.path!`+`File.write`+`chmod 0o600`），供配置页 UI 保存（不写死、admin-gated）。

  纯出站（投查定论）：ezagent 真相源，GitHub 是投影——建 issue / 读 PR / post 评论，无 inbound webhook。
  """

  @api "https://api.github.com"
  @http_opts [{:body_format, :binary}]
  @http_http_opts [{:timeout, 30_000}, {:connect_timeout, 15_000}]
  @creds_content_limit 8_192

  @doc "从 github.yaml 读凭证。返回 `{:ok, %{token, repo}}`。"
  @spec read_creds() :: {:ok, %{token: String.t(), repo: String.t() | nil}} | {:error, term()}
  def read_creds do
    case Ezagent.System.FsResolver.read_yaml(Ezagent.URI.system("credentials", "github.yaml")) do
      {:ok, %{"access_token" => t} = m} when is_binary(t) and t != "" ->
        {:ok, %{token: t, repo: blank_to_nil(Map.get(m, "repo"))}}

      {:ok, _} ->
        {:error, :github_token_missing}

      {:error, _} = err ->
        err
    end
  end

  @doc "写凭证到 `system://credentials/github.yaml`（照 token_store idiom，配置页 UI 保存用）。"
  @spec write_creds(%{required(:access_token) => String.t(), optional(:repo) => String.t() | nil}) ::
          :ok | {:error, term()}
  def write_creds(%{access_token: token} = creds) when is_binary(token) and token != "" do
    repo = blank_to_nil(Map.get(creds, :repo))

    body =
      "access_token: \"#{token}\"\n" <> if(repo, do: "repo: \"#{repo}\"\n", else: "")

    file = Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "github.yaml"))
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, String.slice(body, 0, @creds_content_limit)) do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  def write_creds(_), do: {:error, :access_token_required}

  @doc "在 repo(`owner/name`) 建一个 issue。返回 `{:ok, %{number, url}}`。"
  @spec create_issue(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{number: integer(), url: String.t()}} | {:error, term()}
  def create_issue(token, repo, title, body) do
    case post(token, "/repos/#{repo}/issues", %{title: title, body: body}) do
      {:ok, %{"number" => n, "html_url" => url}} -> {:ok, %{number: n, url: url}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc "在 issue/PR(#number) 下 post 一条评论（issue 与 PR 共用此端点）。返回 `{:ok, comment_url}`。"
  @spec post_comment(String.t(), String.t(), integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def post_comment(token, repo, number, body) do
    case post(token, "/repos/#{repo}/issues/#{number}/comments", %{body: body}) do
      {:ok, %{"html_url" => url}} -> {:ok, url}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc "读一个 PR 的状态（state/merged/head 分支）。返回 `{:ok, %{state, merged, head_ref}}`。"
  @spec get_pull(String.t(), String.t(), integer()) ::
          {:ok, %{state: String.t(), merged: boolean(), head_ref: String.t() | nil}}
          | {:error, term()}
  def get_pull(token, repo, number) do
    case get(token, "/repos/#{repo}/pulls/#{number}") do
      {:ok, %{"state" => s} = m} ->
        {:ok,
         %{state: s, merged: Map.get(m, "merged", false), head_ref: get_in(m, ["head", "ref"])}}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  # --- :httpc helpers（对齐 miro.ex）---------------------------------------

  defp post(token, path, payload) do
    body = Jason.encode!(payload)
    request = {String.to_charlist(@api <> path), headers(token), ~c"application/json", body}

    case :httpc.request(:post, request, @http_http_opts, @http_opts) do
      {:ok, {{_, code, _}, _, resp}} when code in [200, 201] -> Jason.decode(resp)
      {:ok, {{_, code, _}, _, resp}} -> {:error, {:http_status, code, resp}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp get(token, path) do
    request = {String.to_charlist(@api <> path), headers(token)}

    case :httpc.request(:get, request, @http_http_opts, @http_opts) do
      {:ok, {{_, 200, _}, _, resp}} -> Jason.decode(resp)
      {:ok, {{_, code, _}, _, resp}} -> {:error, {:http_status, code, resp}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp headers(token) do
    [
      {~c"Authorization", String.to_charlist("Bearer " <> token)},
      {~c"Accept", ~c"application/vnd.github+json"},
      {~c"User-Agent", ~c"ezagent-kanban"},
      {~c"X-GitHub-Api-Version", ~c"2022-11-28"}
    ]
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
