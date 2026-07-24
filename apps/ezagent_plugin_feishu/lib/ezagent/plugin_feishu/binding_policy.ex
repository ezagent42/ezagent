defmodule EzagentPluginFeishu.BindingPolicy do
  @moduledoc """
  Side-effects of binding a Feishu open_id to a local Ezagent user.

  ## no-unowned-caps north star — eliminate `feishu-binding-policy` (capbac.md §7)

  The bind is ONLY the open_id↔user identity link; it has NO cap-granting
  side-effect — it just ensures the user Kind is alive (so a later session
  dispatch has a target).

  WHY this is safe (no behavior change): the bind's old cap grant was
  REDUNDANT. A bound user already holds `User.default_caps/1`'s session
  baseline — it is applied at spawn via `Ezagent.Entity.User.initial_caps_for_spawn/1`
  (and at create via `Ezagent.Users.create/3`), independent of the bind. So a
  bound Feishu user participates in sessions exactly as any other user does
  today; removing the bind-time re-grant changes nothing they could do.

  HISTORY: pre-PR-144 this granted a `kind=:feishu_chat, behavior=:any` cap.
  PR-144 reduced it to re-granting `User.default_caps/1`'s session baseline.
  The 2026-05-27 capability-action-axis change replaced that with explicit
  per-action caps granted under the non-entity `system://feishu-binding-policy`
  principal — the LAST grant-minter in the Catalog (Decision #154 violation,
  capbac.md §7). This PR removes that redundant re-grant and DELETES the
  principal → `no_unowned` reaches 0.

  NOTE: narrowing `User.default_caps/1` itself (the broad workspace-wide
  session baseline, granted_by `system://bootstrap`) to a per-session,
  granted-at-join model is a SEPARATE, larger refactor (the session-join
  authorization question + the bootstrap-baseline elimination) tracked under
  the per-session work — NOT this PR. This PR keeps `default_caps` unchanged.

  ## Where to extend

  Future per-binding policies (workspace-scoped caps, role-template
  assignment, approval-workflow caps) plug in here — but any cap grant MUST
  route through the `Ezagent.Identity.Grant` chokepoint under a real-entity
  tag (NEVER a `system://` principal). Keep the storage module
  (`UserBinding`) pure and the transport module (`SenderResolver`) unaware
  of cap semantics.

  ## Why a separate module from `UserBinding`

  `UserBinding` is pure storage; `BindingPolicy` is side-effects on
  state change. Tests for storage don't exercise dispatch; tests for
  policy can stub the store.
  """

  @doc """
  Apply binding side-effects: ensure the user Kind is alive.

  This NO LONGER grants any session-participation caps — the old re-grant was
  redundant with `User.default_caps/1` (applied at user spawn/create), so a
  bound user already holds the session baseline. The bind is the open_id↔user
  link only; ensuring the user Kind is alive is its sole side-effect.

  `_admin_uri` (the operator who authorized the bind) is retained in the
  signature for caller stability but is unused now that there is no grant
  to attribute.
  """
  @spec apply(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def apply(user_uri, _admin_uri) do
    # Configurable failure seam for deterministic rollback testing.
    # The real production path is `ensure_user_kind/1` only.
    if Application.get_env(:ezagent_plugin_feishu, :binding_policy_force_failure) do
      {:error, :policy_failure_synthetic}
    else
      ensure_user_kind(user_uri)
    end
  end

  # Bound user might not be live yet (admin types
  # `mix ezagent.feishu.bind ou_xxx entity://user/team-alpha/newcomer` for a
  # brand-new user). Auto-spawn via the owner-gated LocalRuntime facade so the
  # cap dispatch has a target.
  defp ensure_user_kind(user_uri) do
    uri = to_uri(user_uri)

    if Ezagent.LocalRuntime.kind_alive?(uri) do
      :ok
    else
      case Ezagent.LocalRuntime.ensure_started(uri) do
        {:ok, _pid} -> :ok
        err -> err
      end
    end
  end

  defp to_uri(%URI{} = u), do: u
  defp to_uri(s) when is_binary(s), do: Ezagent.URI.new!(s)
end
