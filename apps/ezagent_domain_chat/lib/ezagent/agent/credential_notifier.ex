defmodule Ezagent.Agent.CredentialNotifier do
  @moduledoc """
  #17 PR-C2 — turns a PTY auth-failure signal into an owner notification (no silent mute).

  Subscribes ONCE to the shared `Ezagent.Domain.Pty.Server.auth_failed_all_topic/0`
  (`{:pty_auth_failed, agent_uri, observer}` for every agent). On each event it resolves
  the agent's OWNER via `Ezagent.Behavior.ApiKeys.data_owner/1` (the durable creator_uri
  model — NOT lineage-parent) and notifies them through `Ezagent.Notifications.notify/3`
  with a clickable terminal URL so they can re-`/login`.

  Best-effort: a notify failure is logged, never crashes the notifier (so one bad event
  can't deafen the whole credential-expiry surface).
  """
  use GenServer
  require Logger

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.auth_failed_all_topic())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:pty_auth_failed, %URI{} = agent_uri, observer}, state) do
    case Ezagent.Behavior.ApiKeys.data_owner(agent_uri) do
      %URI{} = owner_uri ->
        notify_owner(owner_uri, agent_uri, observer)

      _ ->
        Logger.warning(
          "CredentialNotifier: auth failure for #{URI.to_string(agent_uri)} (#{inspect(observer)}) " <>
            "but no resolvable owner (creator_uri/lineage) — cannot notify."
        )
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp notify_owner(%URI{} = owner_uri, %URI{} = agent_uri, observer) do
    _ = Ezagent.Notifications.notify(owner_uri, build_notification(agent_uri, observer))
    :ok
  rescue
    error ->
      Logger.warning(
        "CredentialNotifier: notify to #{URI.to_string(owner_uri)} for " <>
          "#{URI.to_string(agent_uri)} raised #{inspect(error)} — auth-failure surface degraded."
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "CredentialNotifier: notify to #{URI.to_string(owner_uri)} threw #{inspect({kind, reason})}."
      )

      :ok
  end

  @doc false
  @spec build_notification(URI.t(), term()) :: map()
  def build_notification(%URI{} = agent_uri, observer) do
    url = terminal_url(agent_uri)

    %{
      type: :agent_auth_failed,
      body: %{
        text:
          "Agent #{URI.to_string(agent_uri)} needs re-login (its credentials are " <>
            "expired/missing). Open its terminal and run `/login`: #{url}",
        agent_uri: agent_uri,
        observer: observer,
        terminal_url: url
      },
      source: __MODULE__
    }
  end

  @doc """
  #17 PR-C2 / D2 — the clickable terminal URL for an agent, built from the
  deployment-configured public host (`EZAGENT_PUBLIC_HOST`, default `app.ezagent.chat`)
  and the Phoenix route `/identities/agents/:uri/terminal` (URL-encoded agent URI).
  """
  @spec terminal_url(URI.t()) :: String.t()
  def terminal_url(%URI{} = agent_uri) do
    host = System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat")
    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    "https://#{host}/identities/agents/#{encoded}/terminal"
  end
end
