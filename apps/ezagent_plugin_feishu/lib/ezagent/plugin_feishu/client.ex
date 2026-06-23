defmodule EzagentPluginFeishu.Client do
  @moduledoc """
  Phase 5 PR 6 — Lark/Feishu HTTP client.

  Two operations needed for the demo:
  1. `tenant_access_token/0` — mint short-lived (~2h) access token from
     `app_id` + `app_secret` (cached in this GenServer; auto-refreshes)
  2. `send_text/2` — POST a text message to a `chat_id`

  Uses :httpc to avoid adding new deps (Req/Tesla would also work but
  this plugin is the only HTTP client in the codebase and zero-dep is
  cleaner per memory feedback_let_it_crash_no_workarounds).

  Credentials read from `system://credentials/feishu.yaml` via
  `Ezagent.System.FsResolver.read_yaml/1` at boot (Resource-unification OI-3).
  If the feishu.yaml is the empty template (`app_id: cli_REPLACE_ME`),
  the plugin still starts but client calls return `{:error,
  :credentials_not_configured}` — operator gets a clear error rather
  than crash-on-load (this matters for dev: operator may run the
  server before filling creds).
  """
  use GenServer
  require Logger

  @lark_base "https://open.feishu.cn/open-apis"

  defstruct [:app_id, :app_secret, token: nil, expires_at: nil]

  # --- public API ---------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Send a text message to a Feishu chat. Returns `:ok` on success,
  `{:error, reason}` on any failure (token mint or send).
  """
  @spec send_text(String.t(), String.t()) :: :ok | {:error, term()}
  def send_text(chat_id, text) when is_binary(chat_id) and is_binary(text) do
    GenServer.call(__MODULE__, {:send_text, chat_id, text}, 10_000)
  end

  # --- Phase 6 PR 14: image / file pass-through --------------------------

  @doc """
  Download a Feishu resource (image, file, audio, video) to the local
  filesystem. Returns `{:ok, path}` on success.

  Path is written under `\$EZAGENT_HOME/<profile>/inbox/feishu/<filename>`
  so the operator can browse what arrived (and CC has a real local
  path to give to `Read` if it wants to inspect contents).
  """
  @spec download_resource(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def download_resource(message_id, file_key, type, filename) do
    GenServer.call(__MODULE__, {:download_resource, message_id, file_key, type, filename}, 30_000)
  end

  @doc "Upload an image. Returns `{:ok, image_key}` for use in send_image/2."
  @spec upload_image(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_image(path), do: GenServer.call(__MODULE__, {:upload_image, path}, 30_000)

  @doc "Upload a file. Returns `{:ok, file_key}` for use in send_file/2."
  @spec upload_file(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_file(path, name), do: GenServer.call(__MODULE__, {:upload_file, path, name}, 30_000)

  @doc "Send an image message (image_key from upload_image/1)."
  @spec send_image(String.t(), String.t()) :: :ok | {:error, term()}
  def send_image(chat_id, image_key) do
    GenServer.call(__MODULE__, {:send_image, chat_id, image_key}, 10_000)
  end

  @doc "Send a file message (file_key from upload_file/2)."
  @spec send_file(String.t(), String.t()) :: :ok | {:error, term()}
  def send_file(chat_id, file_key) do
    GenServer.call(__MODULE__, {:send_file, chat_id, file_key}, 10_000)
  end

  @doc """
  Phase 6 PR 15: react an emoji to a Feishu message. Used as
  acknowledgement so the human sender sees Ezagent received the message.

  `emoji_type` is a Feishu reaction name like "OK", "DONE",
  "HEART", etc. See https://open.feishu.cn/document/.../emojis

  Phase 6 PR 17 (Allen 2026-05-18 "OK 还是要等好几秒"): bypass the
  Client GenServer's mailbox so the react POST doesn't queue behind
  the chat fan-out's send_text calls. Get the token via fast
  `peek_token` then do the HTTP POST in the caller process.
  """
  @spec react(String.t(), String.t()) :: :ok | {:error, term()}
  def react(message_id, emoji_type \\ "OK") when is_binary(message_id) do
    with {:ok, token} <- peek_token() do
      body = %{reaction_type: %{emoji_type: emoji_type}}

      case http_post_json_direct(
             "#{@lark_base}/im/v1/messages/#{message_id}/reactions",
             body,
             [{~c"Authorization", String.to_charlist("Bearer #{token}")}]
           ) do
        {:ok, %{"code" => 0}} -> :ok
        {:ok, %{"code" => code, "msg" => msg}} -> {:error, {:lark_error, code, msg}}
        err -> err
      end
    end
  end

  # Mirror of http_post_json but available outside the GenServer
  # process (so react can run without holding up the Client mailbox).
  defp http_post_json_direct(url, payload, extra_headers) do
    body = Jason.encode!(payload)

    headers = [
      {~c"Content-Type", ~c"application/json; charset=utf-8"} | extra_headers
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 5000}, {:connect_timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, decoded} -> {:ok, decoded}
          err -> err
        end

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, {:http_status, status, to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc "Returns `{:ok, status}` describing the client's credential state."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Fast path for callers that want to do their own HTTP POST without
  serializing on the Client GenServer's mailbox.

  Returns the current cached tenant_access_token (mints one if expired).
  Allen 2026-05-17: react ack was slow because send_text calls queued
  ahead of it in Client's mailbox. Splitting "token mint" (sync, fast)
  from "do POST" (async, can run in parallel) gives back fan-out
  parallelism.
  """
  @spec peek_token() :: {:ok, String.t()} | {:error, term()}
  def peek_token, do: GenServer.call(__MODULE__, :peek_token, 10_000)

  # --- callbacks ----------------------------------------------------------

  @impl true
  def init(_) do
    state =
      case Ezagent.System.FsResolver.read_yaml(feishu_cred_uri()) do
        {:ok, %{"app_id" => app_id, "app_secret" => app_secret} = creds}
        when is_binary(app_id) and is_binary(app_secret) ->
          # Template-stubs have `cli_REPLACE_ME` — flag as un-configured so
          # send_text returns a clear error rather than calling Lark with
          # garbage credentials.
          if String.contains?(app_id, "REPLACE_ME") or String.contains?(app_secret, "REPLACE_ME") do
            Logger.warning(
              "EzagentPluginFeishu.Client: credentials file present but unfilled (cli_REPLACE_ME). " <>
                "Edit #{feishu_cred_path()} to enable."
            )

            %__MODULE__{app_id: nil, app_secret: nil}
          else
            Logger.info("EzagentPluginFeishu.Client: credentials loaded (app_id=#{String.slice(app_id, 0..14)}…)")
            _ = creds
            %__MODULE__{app_id: app_id, app_secret: app_secret}
          end

        {:error, :not_found} ->
          Logger.warning(
            "EzagentPluginFeishu.Client: no feishu.yaml at #{feishu_cred_path()}. " <>
              "Run `mix ezagent.home.init` then fill credentials."
          )

          %__MODULE__{app_id: nil, app_secret: nil}

        err ->
          Logger.error("EzagentPluginFeishu.Client: credential read failed: #{inspect(err)}")
          %__MODULE__{app_id: nil, app_secret: nil}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:send_text, _chat, _text}, _from, %__MODULE__{app_id: nil} = state),
    do: {:reply, {:error, :credentials_not_configured}, state}

  def handle_call({:send_text, chat_id, text}, _from, state) do
    Logger.info(
      "FeishuClient.send_text → POST im/v1/messages receive_id=#{inspect(chat_id)} " <>
        "text_len=#{byte_size(text)}"
    )

    case ensure_token(state) do
      {:ok, token, new_state} ->
        body = %{
          receive_id: chat_id,
          msg_type: "text",
          content: Jason.encode!(%{text: text})
        }

        case http_post_json(
               "#{@lark_base}/im/v1/messages?receive_id_type=chat_id",
               body,
               [{~c"Authorization", String.to_charlist("Bearer #{token}")}]
             ) do
          {:ok, %{"code" => 0}} ->
            Logger.info("FeishuClient.send_text OK (code=0) chat_id=#{inspect(chat_id)}")
            {:reply, :ok, new_state}

          {:ok, %{"code" => code, "msg" => msg}} ->
            Logger.warning(
              "FeishuClient.send_text LARK ERROR chat_id=#{inspect(chat_id)} " <>
                "code=#{code} msg=#{inspect(msg)}"
            )
            {:reply, {:error, {:lark_error, code, msg}}, new_state}

          err ->
            Logger.warning(
              "FeishuClient.send_text TRANSPORT ERROR chat_id=#{inspect(chat_id)} err=#{inspect(err)}"
            )
            {:reply, err, new_state}
        end

      err ->
        Logger.warning(
          "FeishuClient.send_text TOKEN ERROR chat_id=#{inspect(chat_id)} err=#{inspect(err)}"
        )
        {:reply, err, state}
    end
  end

  # --- Phase 6 PR 14: download_resource ---------------------------------

  def handle_call({:download_resource, _, _, _, _}, _from, %__MODULE__{app_id: nil} = state),
    do: {:reply, {:error, :credentials_not_configured}, state}

  def handle_call({:download_resource, message_id, file_key, type, filename}, _from, state) do
    case ensure_token(state) do
      {:ok, token, new_state} ->
        url =
          "#{@lark_base}/im/v1/messages/#{message_id}/resources/#{file_key}?type=#{type}"

        case :httpc.request(
               :get,
               {String.to_charlist(url),
                [{~c"Authorization", String.to_charlist("Bearer #{token}")}]},
               [{:timeout, 30_000}],
               body_format: :binary
             ) do
          {:ok, {{_, 200, _}, _, bytes}} ->
            path = inbox_path(filename)
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, bytes)
            {:reply, {:ok, path}, new_state}

          {:ok, {{_, status, _}, _, body}} ->
            {:reply, {:error, {:http_status, status, to_string(body)}}, new_state}

          {:error, reason} ->
            {:reply, {:error, {:http_error, reason}}, new_state}
        end

      err ->
        {:reply, err, state}
    end
  end

  # --- Phase 6 PR 14: upload_image / upload_file -----------------------

  def handle_call({:upload_image, _}, _from, %__MODULE__{app_id: nil} = state),
    do: {:reply, {:error, :credentials_not_configured}, state}

  def handle_call({:upload_image, path}, _from, state) do
    case ensure_token(state) do
      {:ok, token, new_state} ->
        {:reply,
         multipart_upload(
           "#{@lark_base}/im/v1/images",
           token,
           [{"image_type", "message"}],
           {"image", path}
         )
         |> parse_upload_response("image_key"), new_state}

      err ->
        {:reply, err, state}
    end
  end

  def handle_call({:upload_file, _, _}, _from, %__MODULE__{app_id: nil} = state),
    do: {:reply, {:error, :credentials_not_configured}, state}

  def handle_call({:upload_file, path, name}, _from, state) do
    case ensure_token(state) do
      {:ok, token, new_state} ->
        {:reply,
         multipart_upload(
           "#{@lark_base}/im/v1/files",
           token,
           [{"file_type", "stream"}, {"file_name", name}],
           {"file", path}
         )
         |> parse_upload_response("file_key"), new_state}

      err ->
        {:reply, err, state}
    end
  end

  # --- Phase 6 PR 14: send_image / send_file ---------------------------

  def handle_call({:send_image, chat_id, image_key}, _from, state) do
    send_typed_message(state, chat_id, "image", %{image_key: image_key})
  end

  def handle_call({:send_file, chat_id, file_key}, _from, state) do
    send_typed_message(state, chat_id, "file", %{file_key: file_key})
  end

  def handle_call(:status, _from, state) do
    s = %{
      configured: state.app_id != nil,
      app_id_prefix: state.app_id && String.slice(state.app_id, 0..14),
      token_minted: state.token != nil
    }

    {:reply, s, state}
  end

  def handle_call(:peek_token, _from, %__MODULE__{app_id: nil} = state),
    do: {:reply, {:error, :credentials_not_configured}, state}

  def handle_call(:peek_token, _from, state) do
    case ensure_token(state) do
      {:ok, token, new_state} -> {:reply, {:ok, token}, new_state}
      err -> {:reply, err, state}
    end
  end

  # Helper for the send_image/send_file handle_call clauses — kept
  # below the handle_call/3 clauses so they group contiguously
  # (clause-grouping warning). Phase 6 PR 17: react/2 moved out of
  # the GenServer mailbox; see the public react/2 +
  # http_post_json_direct/3 above.
  defp send_typed_message(%__MODULE__{app_id: nil} = state, _, _, _),
    do: {:reply, {:error, :credentials_not_configured}, state}

  defp send_typed_message(state, chat_id, msg_type, content_map) do
    case ensure_token(state) do
      {:ok, token, new_state} ->
        body = %{
          receive_id: chat_id,
          msg_type: msg_type,
          content: Jason.encode!(content_map)
        }

        case http_post_json(
               "#{@lark_base}/im/v1/messages?receive_id_type=chat_id",
               body,
               [{~c"Authorization", String.to_charlist("Bearer #{token}")}]
             ) do
          {:ok, %{"code" => 0}} -> {:reply, :ok, new_state}
          {:ok, %{"code" => code, "msg" => msg}} -> {:reply, {:error, {:lark_error, code, msg}}, new_state}
          err -> {:reply, err, new_state}
        end

      err ->
        {:reply, err, state}
    end
  end

  # --- token mint + caching ------------------------------------------------

  defp ensure_token(%__MODULE__{token: token, expires_at: exp} = state)
       when is_binary(token) do
    if exp && DateTime.compare(DateTime.utc_now(), exp) == :lt do
      {:ok, token, state}
    else
      mint_token(state)
    end
  end

  defp ensure_token(state), do: mint_token(state)

  defp mint_token(%__MODULE__{app_id: app_id, app_secret: app_secret} = state) do
    case http_post_json(
           "#{@lark_base}/auth/v3/tenant_access_token/internal",
           %{app_id: app_id, app_secret: app_secret},
           []
         ) do
      {:ok, %{"code" => 0, "tenant_access_token" => token, "expire" => seconds_left}} ->
        # Cache 5 minutes shy of expiry to avoid edge-of-validity sends.
        expires_at = DateTime.add(DateTime.utc_now(), seconds_left - 300, :second)
        {:ok, token, %{state | token: token, expires_at: expires_at}}

      {:ok, %{"code" => code, "msg" => msg}} ->
        {:error, {:lark_auth_error, code, msg}}

      err ->
        err
    end
  end

  # --- inbox helpers (Phase 6 PR 14) -----------------------------------

  # Resource-unification P3 (SPEC §10 OI-3): the feishu inbox is a node-global
  # plugin spool under the profile (no `<ws>`) → `system://inbox` via `UriQuery`,
  # then the constant `feishu/` subdir + sanitized filename joined on.
  # Byte-identical to the legacy `profile_dir()/inbox/feishu/<name>` (the `inbox`
  # system type resolves to the profile-level `inbox` Home component).
  defp inbox_path(filename) do
    inbox_dir = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("inbox"))
    Path.join([inbox_dir, "feishu", safe_name(filename)])
  end

  # Resource-unification P3 (SPEC §10 OI-3): the global feishu app credential
  # is a node-global system artifact → `system://credentials/feishu.yaml`. BOTH
  # the operational read (`read_yaml/1` above) and the operator-facing path
  # string flow through the `system://` seam — no raw `Ezagent.Home` /
  # `Home.read_credentials` dependency remains in this caller.
  defp feishu_cred_uri, do: Ezagent.URI.system("credentials", "feishu.yaml")

  defp feishu_cred_path do
    Ezagent.System.FsResolver.path!(feishu_cred_uri())
  end

  # Sanitize a caller-controlled (inbound Feishu attachment) filename into a
  # single safe path component before it is joined under the resolved
  # `system://inbox` dir and written. Strips separators/`..`, caps length, then
  # enforces the SAME segment guarantee the `system://` resolver applies to its
  # own segments (`Ezagent.System.FsResolver.safe_component?/1` — rejects `.`,
  # `..`, empty, NUL, separators); anything that still fails degrades to a fixed
  # safe name rather than targeting the directory itself or crashing the write
  # (codex P3 MEDIUM: validate every appended segment, not just the resolver base).
  defp safe_name(name) when is_binary(name) do
    candidate =
      name
      |> String.replace(["/", "\\", ".."], "_")
      |> String.slice(0, 200)

    if Ezagent.System.FsResolver.safe_component?(candidate), do: candidate, else: "unnamed"
  end

  defp safe_name(_), do: "unnamed"

  # --- multipart upload (Lark expects multipart/form-data) ---------------

  defp multipart_upload(url, token, extra_fields, {field_name, path}) do
    boundary = "----esrPhase6PR14" <> Integer.to_string(System.unique_integer([:positive]))
    file_bytes = File.read!(path)
    filename = Path.basename(path)

    body =
      build_multipart_body(boundary, extra_fields, field_name, filename, file_bytes)

    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{token}")}
    ]

    request = {
      String.to_charlist(url),
      headers,
      String.to_charlist("multipart/form-data; boundary=#{boundary}"),
      body
    }

    case :httpc.request(:post, request, [{:timeout, 30_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case Jason.decode(to_string(resp)) do
          {:ok, %{"code" => 0, "data" => data}} -> {:ok, data}
          {:ok, %{"code" => code, "msg" => msg}} -> {:error, {:lark_error, code, msg}}
          err -> err
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_status, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp build_multipart_body(boundary, fields, file_field, filename, file_bytes) do
    field_parts =
      Enum.map(fields, fn {k, v} ->
        ~s(--#{boundary}\r\nContent-Disposition: form-data; name="#{k}"\r\n\r\n#{v}\r\n)
      end)
      |> IO.iodata_to_binary()

    file_part =
      ~s(--#{boundary}\r\nContent-Disposition: form-data; name="#{file_field}"; filename="#{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n) <>
        file_bytes <>
        "\r\n"

    field_parts <> file_part <> "--#{boundary}--\r\n"
  end

  defp parse_upload_response({:ok, %{} = data}, key), do: {:ok, Map.get(data, key)}
  defp parse_upload_response({:error, _} = err, _), do: err

  # --- :httpc helper -------------------------------------------------------

  defp http_post_json(url, payload, extra_headers) do
    body = Jason.encode!(payload)

    headers =
      [
        {~c"Content-Type", ~c"application/json; charset=utf-8"}
        | extra_headers
      ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 5000}, {:connect_timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, decoded} -> {:ok, decoded}
          err -> err
        end

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, {:http_status, status, to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end
end
