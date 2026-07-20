defmodule Ezagent.World.AdminActions do
  @moduledoc """
  Socket-side admin dispatch handlers for the world plugin.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.World.AdminData

  @doc "Route a world admin action to its handler."
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "admin.registration.save", %{"registration" => params})
      when is_map(params) do
    save_registration(socket, params)
  end

  def handle_dispatch(socket, "admin.smtp.save", %{"smtp" => params}) when is_map(params) do
    save_smtp(socket, params)
  end

  def handle_dispatch(socket, "admin.smtp.test", %{"recipient" => recipient})
      when is_binary(recipient) do
    send_test_email(socket, recipient)
  end

  def handle_dispatch(socket, "admin.smtp.update_recipient", %{"recipient" => recipient})
      when is_binary(recipient) do
    put_settings(socket, %{"smtp_test_recipient" => recipient}, "ok")
  end

  # F9 — bind a Feishu chat → session from the External Mirror surface. The
  # session-level `:bind` cap + per-adapter allow cap + target_ownership_check
  # all run inside `Ezagent.ExternalMirror.bind/5` (the facade); we only pass
  # the caller context off the socket.
  def handle_dispatch(
        socket,
        "external_mirror.bind",
        %{
          "session_uri" => session_uri,
          "adapter_id" => adapter_id,
          "target_id" => target_id
        } = args
      )
      when is_binary(session_uri) and is_binary(adapter_id) and is_binary(target_id) do
    bind_external_mirror(socket, session_uri, adapter_id, target_id, normalize_opts(args))
  end

  def handle_dispatch(socket, "external_mirror.unbind", %{
        "session_uri" => session_uri,
        "adapter_id" => adapter_id,
        "target_id" => target_id
      })
      when is_binary(session_uri) and is_binary(adapter_id) and is_binary(target_id) do
    unbind_external_mirror(socket, session_uri, adapter_id, target_id)
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  @doc "Persist public-registration and invite requirements from the admin settings form."
  @spec save_registration(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def save_registration(socket, params) do
    if Ezagent.Identity.admin?(socket.assigns.current_entity_uri) do
      open? = truthy?(Map.get(params, "open"))
      require_invite? = truthy?(Map.get(params, "require_invite"))

      :ok = Ezagent.AppSettings.put("registration_open", open?)
      :ok = Ezagent.AppSettings.put("registration_require_invite", require_invite?)

      put_settings(socket, %{"registration_flash" => "Registration settings saved."}, "ok")
    else
      put_settings(
        socket,
        %{"registration_flash" => "error:unauthorized"},
        "error:unauthorized"
      )
    end
  rescue
    err ->
      put_settings(
        socket,
        %{"registration_flash" => "error:#{inspect(err)}"},
        "error:registration_save_failed"
      )
  end

  @doc "Persist SMTP config from the world settings form."
  @spec save_smtp(Phoenix.LiveView.Socket.t(), map()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def save_smtp(socket, params) do
    cfg = %{
      "host" => params |> Map.get("host", "") |> to_string() |> String.trim(),
      "port" => params |> Map.get("port", "") |> to_string() |> String.trim(),
      "username" => params |> Map.get("username", "") |> to_string() |> String.trim(),
      "password" => Map.get(params, "password", ""),
      "from_address" => params |> Map.get("from_address", "") |> to_string() |> String.trim(),
      "tls" => Map.get(params, "tls", "true") in ["true", "on", true]
    }

    cfg =
      if cfg["password"] == "" do
        existing = Ezagent.AppSettings.get("smtp_config") || %{}
        Map.put(cfg, "password", Map.get(existing, "password", ""))
      else
        cfg
      end

    :ok = Ezagent.AppSettings.put("smtp_config", cfg)

    put_settings(socket, %{"smtp_flash" => "SMTP config saved.", "smtp_test_result" => nil}, "ok")
  rescue
    err ->
      put_settings(
        socket,
        %{"smtp_flash" => nil, "smtp_test_result" => "error:#{inspect(err)}"},
        "error:smtp_save_failed"
      )
  end

  @doc "Send a settings-page magic-link test email."
  @spec send_test_email(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def send_test_email(socket, recipient) when is_binary(recipient) do
    recipient = String.trim(recipient)

    cond do
      recipient == "" ->
        put_settings(
          socket,
          %{"smtp_test_recipient" => recipient, "smtp_test_result" => "error:recipient_required"},
          "error:recipient_required"
        )

      not Ezagent.AppSettings.mail_configured?() ->
        put_settings(
          socket,
          %{
            "smtp_test_recipient" => recipient,
            "smtp_test_result" => "error:smtp_not_configured"
          },
          "error:smtp_not_configured"
        )

      true ->
        case deliver_magic_link(recipient, test_magic_link_url()) do
          {:ok, _} ->
            put_settings(
              socket,
              %{
                "smtp_test_recipient" => recipient,
                "smtp_test_result" => "ok:delivered"
              },
              "ok"
            )

          {:error, reason} ->
            put_settings(
              socket,
              %{
                "smtp_test_recipient" => recipient,
                "smtp_test_result" => "error:#{inspect(reason)}"
              },
              "error:smtp_send_failed"
            )
        end
    end
  end

  @doc """
  Bind a Feishu chat → session via `Ezagent.ExternalMirror.bind/5`, then refresh
  the External Mirror surface's bindings list. The caller identity + caps come
  off the socket — the facade enforces all authorization.
  """
  @spec bind_external_mirror(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def bind_external_mirror(socket, session_uri_str, adapter_id, target_id, opts) do
    case external_mirror_bind_result(
           session_uri_str,
           adapter_id,
           target_id,
           opts,
           caller_ctx(socket)
         ) do
      {:ok, session_uri, _result} ->
        put_external_mirror_state(socket, session_uri, "ok")

      {:error, :invalid_session_uri} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_session_uri")}

      {:error, %URI{} = session_uri, reason} ->
        put_external_mirror_state(socket, session_uri, "error:" <> reason_string(reason))
    end
  end

  @doc "Unbind a Feishu chat from a session via `Ezagent.ExternalMirror.unbind/4`."
  @spec unbind_external_mirror(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def unbind_external_mirror(socket, session_uri_str, adapter_id, target_id) do
    case external_mirror_unbind_result(session_uri_str, adapter_id, target_id, caller_ctx(socket)) do
      {:ok, session_uri, _result} ->
        put_external_mirror_state(socket, session_uri, "ok")

      {:error, :invalid_session_uri} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_session_uri")}

      {:error, %URI{} = session_uri, reason} ->
        put_external_mirror_state(socket, session_uri, "error:" <> reason_string(reason))
    end
  end

  @typep bind_fun ::
           (URI.t(), String.t(), String.t(), map(), map() -> {:ok, map()} | {:error, term()})
  @typep unbind_fun :: (URI.t(), String.t(), String.t(), map() -> {:ok, map()} | {:error, term()})

  @doc """
  Pure wiring seam (mirrors `ConversationActions.create_session_result/5`): parse
  the session URI, run the bind closure, and normalize the result.

  Returns `{:ok, session_uri, result}` on success, `{:error, session_uri, reason}`
  when the facade rejects the bind (the surface still refreshes for that
  session), or `{:error, :invalid_session_uri}` without ever calling the closure
  when the URI is not a session.
  """
  @spec external_mirror_bind_result(String.t(), String.t(), String.t(), map(), map(), bind_fun()) ::
          {:ok, URI.t(), map()} | {:error, URI.t(), term()} | {:error, :invalid_session_uri}
  def external_mirror_bind_result(
        session_uri_str,
        adapter_id,
        target_id,
        opts,
        ctx,
        bind_fun \\ &Ezagent.ExternalMirror.bind/5
      ) do
    case safe_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        case bind_fun.(session_uri, adapter_id, target_id, opts, ctx) do
          {:ok, result} -> {:ok, session_uri, result}
          {:error, reason} -> {:error, session_uri, reason}
        end

      :error ->
        {:error, :invalid_session_uri}
    end
  end

  @doc "Pure wiring seam for unbind — see `external_mirror_bind_result/6`."
  @spec external_mirror_unbind_result(String.t(), String.t(), String.t(), map(), unbind_fun()) ::
          {:ok, URI.t(), map()} | {:error, URI.t(), term()} | {:error, :invalid_session_uri}
  def external_mirror_unbind_result(
        session_uri_str,
        adapter_id,
        target_id,
        ctx,
        unbind_fun \\ &Ezagent.ExternalMirror.unbind/4
      ) do
    case safe_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        case unbind_fun.(session_uri, adapter_id, target_id, ctx) do
          {:ok, result} -> {:ok, session_uri, result}
          {:error, reason} -> {:error, session_uri, reason}
        end

      :error ->
        {:error, :invalid_session_uri}
    end
  end

  @doc "Parse a `session://` URI string, returning `:error` for any other scheme."
  @spec safe_session_uri(String.t()) :: {:ok, URI.t()} | :error
  def safe_session_uri(str) when is_binary(str) do
    case Ezagent.URI.new!(str) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def safe_session_uri(_), do: :error

  defp caller_ctx(socket) do
    %{
      caller: socket.assigns.current_entity_uri,
      caps: Ezagent.World.PresenterCaps.load(socket)
    }
  end

  # Pull the optional `opts` map off the dispatch args; default to %{}.
  defp normalize_opts(%{"opts" => opts}) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  defp truthy?(value), do: value in [true, "true", "on", 1, "1"]

  defp put_external_mirror_state(socket, %URI{} = session_uri, status) do
    bindings = AdminData.external_mirror_bindings_for(session_uri)
    state = Map.put(socket.assigns.world_state, "bindings", bindings)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, status)
     |> push_event("world:state", %{"bindings" => bindings})}
  end

  defp put_settings(socket, updates, status) do
    settings =
      socket.assigns.current_entity_uri
      |> AdminData.settings_state()
      |> Map.merge(updates)

    state =
      socket.assigns.world_state
      |> Map.put("settings", settings)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, status)
     |> push_event("world:state", %{"settings" => settings})}
  end

  defp deliver_magic_link(recipient, url) do
    mailer = Module.concat([EzagentWeb, Mailer])

    if Code.ensure_loaded?(mailer) and function_exported?(mailer, :deliver_magic_link, 2) do
      apply(mailer, :deliver_magic_link, [recipient, url])
    else
      {:error, :mailer_not_loaded}
    end
  end

  defp test_magic_link_url do
    endpoint = Module.concat([EzagentWeb, Endpoint])

    base =
      if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :url, 0) do
        apply(endpoint, :url, [])
      else
        "http://localhost:4000"
      end

    base <> "/auth/magic/test-token-from-settings-page"
  end
end
