defmodule EzagentPluginFeishu.UserBindingSeed.DispatchAdapter do
  @moduledoc """
  The ONLY place the Feishu user-binding seed importer touches dispatch
  (handoff B1 Phase 1). Wraps the Phase-0-proven canonical-admin operator
  seam — `Ezagent.Invocation.with_admin_operator/2` +
  `Ezagent.Invocation.dispatch/1` — for the two `UserBinding` actions the
  importer needs:

  - `list_current/1` — a formal dispatch READ (`:list_feishu_bindings`),
    used for preflight classification. Reads flow through dispatch too —
    not just writes — so this module never needs to call the raw storage
    module (`EzagentPluginFeishu.UserBinding`) directly.
  - `bind/3` — a formal dispatch WRITE (`:bind`), used only for rows the
    preflight classified `:absent`.

  `ctx.caps` starts EMPTY on every call here; the framework mints the
  concrete target-signed action cap via `materialize_admin_action_cap/1`
  (see the Phase 0 proof in `integration/boot_dispatch_feasibility_test.exs`).
  No raw storage, no direct handler call, no forged caps, no new system
  principal.
  """

  @doc """
  List the Feishu bindings currently visible for `workspace_uri`, via a
  real dispatch to `:list_feishu_bindings` (workspace-scoped by the
  Behavior's own handler — see moduledoc of `UserBindingSeed` for why
  this is necessarily per-workspace).
  """
  @spec list_current(URI.t()) :: {:ok, [map()]} | {:error, term()}
  def list_current(%URI{scheme: "workspace"} = workspace_uri) do
    dispatch(action_target(workspace_uri, "list_feishu_bindings"), %{})
  end

  @doc """
  Bind `open_id` to `user_uri` under `workspace_uri`, via a real dispatch
  to `:bind`. Callers MUST only invoke this for preflight-classified
  `:absent` rows — this module has no opinion on that; it is the
  orchestrator's (`UserBindingSeed`) job.
  """
  @spec bind(URI.t(), String.t(), URI.t()) :: {:ok, map()} | {:error, term()}
  def bind(%URI{scheme: "workspace"} = workspace_uri, open_id, %URI{} = user_uri)
      when is_binary(open_id) do
    target = action_target(workspace_uri, "bind")
    dispatch(target, %{open_id: open_id, user_uri: user_uri})
  end

  defp action_target(%URI{} = workspace_uri, action_name) do
    Ezagent.URI.new!("#{URI.to_string(workspace_uri)}?action=feishu_user_bindings.#{action_name}")
  end

  # B-layer (DEFERRED): canonical-admin auth + signed action-cap minting
  # via admin_uri() + with_admin_operator is NOT yet integrated.
  # This module is a placeholder — when configured as :seed_executor,
  # every call raises explicitly until boot-auth integration lands.
  defp dispatch(_target, _args) do
    raise """
    DispatchAdapter: canonical-admin auth integration is NOT yet implemented.
    The B-layer operator/auth adapter is deferred. Until it lands, use the
    permission-neutral FakeExecutor for tests, and do not configure
    DispatchAdapter as :seed_executor in production.
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
