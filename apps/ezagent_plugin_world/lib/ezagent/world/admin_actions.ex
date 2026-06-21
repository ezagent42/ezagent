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

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
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
    err -> put_settings(socket, %{"smtp_flash" => nil, "smtp_test_result" => "error:#{inspect(err)}"}, "error:smtp_save_failed")
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

      not Ezagent.AppSettings.smtp_configured?() ->
        put_settings(
          socket,
          %{"smtp_test_recipient" => recipient, "smtp_test_result" => "error:smtp_not_configured"},
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
