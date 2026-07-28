defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapter do
  @moduledoc """
  Production executor seam for the Feishu user-binding importer.

  The permission-neutral B1 A-layer calls an injected function port with
  `list_current` arity 1 and `bind` arity 3 functions. This adapter obtains the
  operator identity from runtime configuration and delegates both operations
  through the same `Ezagent.Cmd` → `Ezagent.Router` boundary as other reviewed
  framework adapters.

  Main currently supports exact action-cap materialization only for the
  canonical admin inside `Ezagent.Invocation.with_admin_operator/2`. A
  configured non-admin operator therefore fails closed rather than receiving
  invented authority. This module creates no capability, principal, or
  workspace and performs no raw storage or direct handler access.
  """

  alias Ezagent.{Cmd, Invocation, Router}

  @doc "Construct the production seed executor function port."
  @spec port() :: %{
          list_current: (URI.t() -> {:ok, [map()]} | {:error, term()}),
          bind: (URI.t(), String.t(), URI.t() -> {:ok, term()} | {:error, term()})
        }
  def port do
    %{list_current: &list_current/1, bind: &bind/3}
  end

  @doc "List current bindings through a synchronous trusted-internal command."
  @spec list_current(URI.t()) :: {:ok, [map()]} | {:error, term()}
  def list_current(%URI{scheme: "workspace"} = workspace_uri) do
    dispatch(workspace_uri, :list_feishu_bindings, %{})
  end

  @doc """
  Bind one preflight-classified absent row through a synchronous
  trusted-internal command.
  """
  @spec bind(URI.t(), String.t(), URI.t()) :: {:ok, term()} | {:error, term()}
  def bind(%URI{scheme: "workspace"} = workspace_uri, open_id, %URI{} = user_uri)
      when is_binary(open_id) do
    dispatch(workspace_uri, :bind, %{open_id: open_id, user_uri: user_uri})
  end

  defp dispatch(%URI{} = workspace_uri, action, args) do
    with {:ok, operator} <- operator_uri() do
      Invocation.with_admin_operator(operator, fn ->
        workspace_uri
        |> Cmd.trusted_internal(action, args, operator, %{
          authenticated_principal: operator,
          caps: MapSet.new(),
          reply: {:caller_inbox, self()},
          mode: :call
        })
        |> Router.dispatch()
      end)
    end
  end

  defp operator_uri do
    case Application.get_env(:ezagent_plugin_feishu, :seed_operator_uri) do
      nil ->
        {:error, :seed_operator_not_configured}

      "" ->
        {:error, :seed_operator_not_configured}

      %URI{} = uri ->
        validate_operator(uri)

      value when is_binary(value) ->
        case Ezagent.URI.parse(value) do
          {:ok, uri} -> validate_operator(uri)
          {:error, _reason} -> {:error, :invalid_seed_operator_uri}
        end

      _other ->
        {:error, :invalid_seed_operator_uri}
    end
  end

  defp validate_operator(%URI{} = operator) do
    canonical_admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(operator) == Ezagent.URI.stable_key(canonical_admin) do
      {:ok, operator}
    else
      {:error, :unsupported_seed_operator}
    end
  rescue
    ArgumentError -> {:error, :invalid_seed_operator_uri}
  end

  @doc """
  Shared token resolution for legacy mix task wrappers.
  Returns the token string or raises `Mix.Error` with a clear auth message.
  """
  @spec resolve_token!(keyword()) :: String.t()
  def resolve_token!(opts) do
    case opts[:token] || System.get_env("EZAGENT_USER_TOKEN") do
      nil -> Mix.raise("authentication required. Pass --token <token> or set EZAGENT_USER_TOKEN")
      "" -> Mix.raise("authentication required. Pass --token <token> or set EZAGENT_USER_TOKEN")
      t -> t
    end
  end
end
