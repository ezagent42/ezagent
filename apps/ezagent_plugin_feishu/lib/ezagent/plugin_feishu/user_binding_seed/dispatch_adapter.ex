defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapter do
  @moduledoc """
  Reserved production executor seam for the Feishu user-binding importer.

  The permission-neutral B1 A-layer calls an injected function port with
  `list_current` arity 1 and `bind` arity 3 functions. This B-layer adapter is
  deliberately not connected to a runtime operator or boot-authorization
  source yet, so both operations fail closed. It performs no dispatch, raw
  storage access, direct handler call, capability construction, or principal
  provisioning.

  A later thin integration may implement this seam only after it has a real
  runtime source for operator identity and authorization.
  """

  @doc "Construct the reserved production seed executor function port."
  @spec port() :: %{
          list_current: (URI.t() -> no_return()),
          bind: (URI.t(), String.t(), URI.t() -> no_return())
        }
  def port do
    %{list_current: &list_current/1, bind: &bind/3}
  end

  @doc """
  Reserved read operation for the deferred production executor. Raises until
  boot authorization integration is configured.
  """
  @spec list_current(URI.t()) :: no_return()
  def list_current(%URI{scheme: "workspace"} = workspace_uri) do
    dispatch(action_target(workspace_uri, "list_feishu_bindings"), %{})
  end

  @doc """
  Reserved bind operation for the deferred production executor. Raises until
  boot authorization integration is configured. The importer only requests it
  for preflight-classified `:absent` rows.
  """
  @spec bind(URI.t(), String.t(), URI.t()) :: no_return()
  def bind(%URI{scheme: "workspace"} = workspace_uri, open_id, %URI{} = user_uri)
      when is_binary(open_id) do
    target = action_target(workspace_uri, "bind")
    dispatch(target, %{open_id: open_id, user_uri: user_uri})
  end

  defp action_target(%URI{} = workspace_uri, action_name) do
    Ezagent.URI.new!("#{URI.to_string(workspace_uri)}?action=feishu_user_bindings.#{action_name}")
  end

  # B-layer (DEFERRED): no runtime operator or boot authorization integration
  # exists. This placeholder must fail closed rather than dispatching, writing
  # raw storage, or inventing authorization.
  defp dispatch(_target, _args) do
    raise """
    DispatchAdapter: seed executor/boot authorization is not configured.
    The B-layer runtime operator/auth integration is deferred. Until it lands,
    use the permission-neutral FakeExecutor only in tests and do not configure
    DispatchAdapter.port/0 as :seed_executor_port in production.
    """
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
