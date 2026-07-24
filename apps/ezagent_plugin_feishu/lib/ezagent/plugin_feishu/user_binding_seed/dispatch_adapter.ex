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

  alias Ezagent.Invocation

  @doc """
  List the Feishu bindings currently visible for `workspace_uri`, via a
  real dispatch to `:list_feishu_bindings` (workspace-scoped by the
  Behavior's own handler — see moduledoc of `UserBindingSeed` for why
  this is necessarily per-workspace).
  """
  @spec list_current(URI.t()) :: {:ok, [map()]} | {:error, term()}
  def list_current(%URI{scheme: "workspace"} = workspace_uri) do
    target = action_target(workspace_uri, "list_feishu_bindings")

    case dispatch(target, %{}) do
      {:ok, %{bindings: bindings}} -> {:ok, bindings}
      {:error, _} = err -> err
    end
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

  # B-layer (DEFERRED): canonical-admin auto-elevation via admin_uri() +
  # with_admin_operator. This module is only reachable when explicitly
  # configured as `:seed_executor` — the importer's nil-executor guard
  # ensures production without auth fails with `:seed_executor_not_configured`.
  # Runtime operator/auth adapter integration is a separate B-layer slice.
  defp dispatch(%URI{} = target, args) do
    admin = Ezagent.Entity.User.admin_uri()

    Invocation.with_admin_operator(admin, fn ->
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new(),
          reply: {:caller_inbox, self()}
        }
      })
    end)
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
