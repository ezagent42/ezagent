defmodule Ezagent.Agent.CredentialNotifier do
  @moduledoc """
  #17 PR-C2 — turns a PTY auth-failure signal into an owner notification (no silent mute).

  Subscribes ONCE to the shared `Ezagent.Domain.Pty.Server.auth_failed_all_topic/0`
  (`{:pty_auth_failed, agent_uri, observer}` for every agent). On each event it resolves
  the agent's OWNER via `Ezagent.ActionSet.ApiKeys.data_owner/1` (the durable creator_uri
  model — NOT lineage-parent) and notifies them through `Ezagent.Notifications.notify/3`
  with a clickable terminal URL so they can re-`/login`.

  Best-effort: a notify failure is logged, never crashes the notifier (so one bad event
  can't deafen the whole credential-expiry surface).
  """
  use GenServer
  require Logger

  alias Ezagent.Domain.Pty.Server, as: PtyServer
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.auth_failed_all_topic())

    {:ok,
     %{
       reconcile_fun: Keyword.get(opts, :reconcile_fun, &AgentAdmission.reconcile_auth_failure/1)
     }}
  end

  @impl true
  def handle_info(
        {:pty_auth_failed, %URI{} = agent_uri, observer},
        %{reconcile_fun: reconcile_fun} = state
      ) do
    owner = resolve_user_owner(agent_uri)
    reconcile_joined_admission(agent_uri, reconcile_fun)

    case owner do
      %URI{} = owner_uri ->
        notify_owner(owner_uri, agent_uri, observer)

      :no_owner ->
        Logger.warning(
          "CredentialNotifier: auth failure for #{URI.to_string(agent_uri)} (#{inspect(observer)}) " <>
            "but no resolvable USER owner (creator chain) — cannot notify."
        )
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp reconcile_joined_admission(agent_uri, reconcile_fun) do
    case reconcile_fun.(agent_uri) do
      :ok ->
        :ok

      {:error, reason} ->
        log_reconciliation_failure(agent_uri, reason)

      other ->
        log_reconciliation_failure(agent_uri, {:unexpected_result, other})
    end
  rescue
    error ->
      log_reconciliation_failure(agent_uri, {:raised, error})
  catch
    kind, reason ->
      log_reconciliation_failure(agent_uri, {kind, reason})
  end

  defp log_reconciliation_failure(agent_uri, reason) do
    Logger.warning(
      "CredentialNotifier: admission reconciliation for #{URI.to_string(agent_uri)} " <>
        "failed with #{inspect(reason)}; owner notification will still be attempted."
    )

    :ok
  end

  # codex PR-C2 review P2 — `ApiKeys.data_owner/1`'s lineage fallback can return a
  # non-user agent (a worker's `spawned_by` is the ORCHESTRATOR), and
  # `Notifications.notify/3` only accepts `entity://user/...`. Walk the creation chain
  # (each agent's data_owner) up to the human user; bounded depth guards cycles.
  defp resolve_user_owner(uri, depth \\ 8)
  defp resolve_user_owner(_uri, 0), do: :no_owner

  defp resolve_user_owner(%URI{} = uri, depth) do
    case Ezagent.ActionSet.ApiKeys.data_owner(uri) do
      %URI{scheme: "entity"} = owner -> resolve_entity_owner(owner, depth)
      _ -> :no_owner
    end
  end

  defp resolve_user_owner(_other, _depth), do: :no_owner

  defp resolve_entity_owner(%URI{} = owner, depth) do
    cond do
      Ezagent.URI.type?(owner, :user) -> owner
      Ezagent.URI.type?(owner, :agent) -> resolve_user_owner(owner, depth - 1)
      true -> :no_owner
    end
  end

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
    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    "#{public_base_url()}/identities/agents/#{encoded}/terminal"
  end

  # codex PR-C2 review P2 — honor the deployment's configured public origin
  # (EZAGENT_PUBLIC_SCHEME / _HOST / _PORT, per config/runtime.exs) so the clickable
  # link points at the right place in https-prod AND http+port dev/Tailscale.
  defp public_base_url do
    scheme =
      System.get_env("EZAGENT_PUBLIC_SCHEME") ||
        Application.get_env(:ezagent_domain_session, :public_scheme, "http")

    host =
      System.get_env("EZAGENT_PUBLIC_HOST") ||
        Application.get_env(:ezagent_domain_session, :public_host, "localhost")

    configured_port = Application.get_env(:ezagent_domain_session, :public_port)
    default_port = if scheme == "https", do: "443", else: "80"

    authority =
      case System.get_env("EZAGENT_PUBLIC_PORT") || configured_port do
        nil ->
          host

        "" ->
          host

        port when is_integer(port) ->
          authority_for_port(host, Integer.to_string(port), default_port)

        ^default_port ->
          host

        port ->
          "#{host}:#{port}"
      end

    "#{scheme}://#{authority}"
  end

  defp authority_for_port(host, port, port), do: host
  defp authority_for_port(host, port, _default_port), do: "#{host}:#{port}"
end
