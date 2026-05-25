defmodule EzagentPluginFeishu.BindingPolicy do
  @moduledoc """
  Side-effects of binding a Feishu open_id to a local ESR user.

  ## PR #144 SPEC v2 §5.8 — simplified after `feishu_chat` Kind deletion

  Pre-PR-144 this module granted a `kind=:feishu_chat, behavior=:any`
  cap on bind, because the bound user dispatched into the
  `feishu://oc_xxx` Receiver Kind directly. With the Kind deleted,
  the bound user's path is now:

      Feishu (open_id) → entity://user/<X> → session://<Y>?action=chat.send

  All caps the user needs to *use* a Feishu binding come from
  `Ezagent.Entity.User.default_caps/0` (`kind=:session, behavior=:any,
  instance=:any`). Bind-time policy therefore reduces to: ensure the
  user Kind is alive and ensure the default caps are present.

  ## Where to extend

  Future per-binding policies (e.g. workspace-scoped caps when the
  bound chat is part of a tenant boundary, role-template assignment,
  approval-workflow caps) plug in here. Keep the storage module
  (`UserBinding`) pure and the transport module (`SenderResolver`)
  unaware of cap semantics.

  ## Why a separate module from `UserBinding`

  `UserBinding` is pure storage; `BindingPolicy` is side-effects on
  state change. Tests for storage don't exercise dispatch; tests for
  policy can stub the store.
  """

  alias Ezagent.{Capability, Invocation}

  @doc """
  Apply binding side-effects: ensure the user Kind is alive and the
  baseline session-participation caps are granted. Idempotent —
  re-bind won't double-grant (MapSet semantics in Identity slice).

  `admin_uri` = the operator who authorized the bind (for granted_by
  attribution + dispatch ctx).
  """
  @spec apply(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def apply(user_uri, admin_uri) do
    with :ok <- ensure_user_kind(user_uri) do
      ensure_user_default_caps(user_uri, admin_uri)
    end
  end

  # Bound user might not be live yet (admin types
  # `mix ezagent.feishu.bind ou_xxx entity://user/team-alpha/newcomer` for a
  # brand-new user). Auto-spawn via SpawnRegistry so the cap dispatch
  # has a target.
  defp ensure_user_kind(user_uri) do
    uri = to_uri(user_uri)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          err -> err
        end
    end
  end

  # Top up the default user caps so a freshly-bound delegate can
  # actually act as a session participant. Identity slice uses MapSet
  # semantics so this is idempotent — already-granted caps don't
  # double-up.
  #
  # The caps themselves come from `Ezagent.Entity.User.default_caps/0`
  # — this module doesn't know what "default" means, it only ensures
  # the baseline is applied.
  defp ensure_user_default_caps(user_uri, admin_uri) do
    # Phase 9 PR-3 (SPEC v3 §4.5): default caps are workspace-scoped
    # — derive the bound user's workspace from their URI.
    workspace_uri = Ezagent.URI.entity_workspace_uri(to_uri(user_uri))

    workspace_uri
    |> Ezagent.Entity.User.default_caps()
    |> Enum.reduce_while(:ok, fn cap, _acc ->
      case grant_cap(user_uri, admin_uri, cap) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp grant_cap(user_uri, _admin_uri, %Capability{} = cap) do
    target = URI.new!("#{to_str(user_uri)}?action=identity.grant_cap")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{cap: cap},
      # SPEC caps-cleanup-v1 §4.4 — re-grant of default caps on
      # Feishu bind is a policy action, not operator-driven; runs
      # under `system://feishu-binding-policy` per the closed Catalog.
      # The operator-supplied `admin_uri` was the previous
      # ambient-authority caller and is no longer load-bearing.
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("feishu-binding-policy"),
        caps: Ezagent.SystemPrincipal.caps("system://feishu-binding-policy"),
        reply: :sync
      }
    }

    case Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      err -> err
    end
  end

  defp to_uri(%URI{} = u), do: u
  defp to_uri(s) when is_binary(s), do: URI.parse(s)

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
