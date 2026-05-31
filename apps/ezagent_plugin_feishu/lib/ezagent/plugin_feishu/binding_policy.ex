defmodule EzagentPluginFeishu.BindingPolicy do
  @moduledoc """
  Side-effects of binding a Feishu open_id to a local ESR user.

  ## PR #144 SPEC v2 §5.8 — simplified after `feishu_chat` Kind deletion

  Pre-PR-144 this module granted a `kind=:feishu_chat, behavior=:any`
  cap on bind, because the bound user dispatched into the
  `feishu://oc_xxx` Receiver Kind directly. With the Kind deleted,
  the bound user's path is now:

      Feishu (open_id) → entity://user/<X> → session://<Y>?action=chat.send

  All caps the user needs to *use* a Feishu binding are
  session-participation caps. Bind-time policy therefore reduces to:
  ensure the user Kind is alive and ensure the per-action
  session-participation caps are present (see `session_participation_caps/1`).

  Pre-SPEC `2026-05-27-capability-action-axis` this re-granted
  `Ezagent.Entity.User.default_caps/1`'s single
  `kind: :session, behavior: :any, action: :any, instance: :any` cap.
  That cap shape, granted under the non-admin
  `system://feishu-binding-policy` principal, is now rejected by
  `IdentityAdmin.invoke(:grant_cap)`'s §3.6.1(b) grant-boundary
  check with `:wildcard_action_grant_requires_admin_authority`. The
  fix is structural: grant the explicit per-action caps the bound
  user actually invokes, not a behavior-wildcard.

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

  ## SPEC 2026-05-27 capability-action-axis §3.6.1(b)

  The re-grant path dispatches `identity.grant_cap` under
  `system://feishu-binding-policy` — a non-admin system principal.
  Per §3.6.1(b) any `action: :any` grant from a non-admin granter
  on a non-scope-bounded cap is rejected with
  `:wildcard_action_grant_requires_admin_authority`.

  Pre-PR-the structural fix this re-granted `User.default_caps/1`'s
  single `kind: :session, behavior: :any, action: :any, instance: :any`
  cap, which §3.6.1(b) (correctly) refused. The structural fix is NOT
  to widen the principal's catalog entry, but to grant the EXPLICIT
  per-Behavior + per-action caps the bound user will actually
  invoke (per Allen 2026-05-27).

  ### What a bound Feishu user actually invokes

  A Feishu-bound user dispatches `chat.send` on a Session, joins/leaves
  sessions, and subscribes to session history via `Publisher.SessionImpl`.

  They do NOT invoke `Chat :receive` directly — fan-out dispatches
  `chat.receive` to recipient User/Agent Kinds under
  `system://chat-router` caps (not the bound user's caps), and
  `:receive` is registered against User+Agent Kinds, not Session
  (see `ezagent_domain_chat/application.ex:609-610`).

  They do NOT invoke `Chat :set_working_copy` (orchestrator-only,
  gated separately in `Chat.invoke(:set_working_copy)`).

  They do NOT invoke `ExternalMirror :bind / :unbind / :list_bindings`
  (admin-only adapter wiring, system-principal-routed at boot).
  """
  @spec apply(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def apply(user_uri, admin_uri) do
    with :ok <- ensure_user_kind(user_uri) do
      ensure_user_default_caps(user_uri, admin_uri)
    end
  end

  # Session-Kind Behaviors a bound Feishu user must invoke as a
  # session participant. Each entry pairs a Behavior module with the
  # exact action atoms `BindingPolicy.apply/2` grants — NO `:any`.
  #
  # SPEC 2026-05-27 capability-action-axis: explicit action atoms
  # close the §3.6.1(b) over-grant surface that a single
  # `behavior: :any, action: :any` cap would expose. Multiple caps
  # per Behavior (one per action) replace the wildcard cap.
  #
  # Action INTENTIONALLY OMITTED:
  #
  #   * `Ezagent.Behavior.Chat :receive` — `:receive` is registered
  #     against the USER + AGENT Kinds (Chat fan-out delivers
  #     `chat.receive` to recipient `entity://` Kinds), NOT against
  #     the Session Kind: see
  #     `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:609-610`.
  #     The fan-out dispatch runs under `system://chat-router` caps
  #     (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:1215`),
  #     NOT the bound user's own caps. A `kind: :session, behavior: Chat,
  #     action: :receive` cap therefore never matches a real dispatch
  #     and would be dead weight.
  #
  #   * `Ezagent.Behavior.Chat :set_working_copy` — orchestrator-only
  #     action; gated separately inside `Chat.invoke(:set_working_copy)`
  #     via `working_copy_write_authorized?/1`. Granting it to a
  #     bound user would not break the orchestrator gate (defense in
  #     depth), but the cap would be useless and growing the user's
  #     slice with no-op rows is pure cost.
  #
  #   * `Ezagent.Behavior.ExternalMirror` (bind/unbind/list_bindings)
  #     — adapter wiring is workspace-admin territory; routed via
  #     `system://adapter-install` / `system://boot-reconciler` (closed
  #     Catalog) at boot, never user-driven.
  @session_chat_actions [:send, :join, :leave]
  @session_publisher_actions [:subscribe_from, :snapshot, :history]

  @doc """
  Returns the per-action cap list `apply/2` will grant for a user
  scoped to `workspace_uri`.

  **`@doc false` — exposed for the regression test in
  `apps/ezagent_plugin_feishu/test/binding_policy_test.exs` so a
  contributor reverting the grant list directly drives a test
  failure (codex r1 HIGH-1: parallel fixture vs production drift).**

  Do not call from production code — `apply/2` is the public
  side-effecting surface.
  """
  @doc false
  @spec caps_for_apply(URI.t()) :: [Capability.t()]
  def caps_for_apply(%URI{scheme: "workspace"} = workspace_uri) do
    session_participation_caps(workspace_uri)
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

  # Top up the bound user's session-participation caps. Identity slice
  # uses MapSet semantics so this is idempotent — already-granted caps
  # don't double-up.
  #
  # SPEC 2026-05-27 capability-action-axis §3.6.1(b): we grant ONE cap
  # per `(Behavior, action)` pair instead of the legacy single
  # `behavior: :any, action: :any` cap. The `system://feishu-binding-policy`
  # principal does not hold admin shape, so an `action: :any` grant
  # from this site is rejected (correctly) by `IdentityAdmin.invoke(:grant_cap)`'s
  # `check_action_wildcard_grant_authorized/2` gate. The per-action
  # caps below pass that gate because their `action` field is a
  # concrete atom; they're then matched at dispatch step 5.5 against
  # the Behavior's `required_caps/0` entry for the same action.
  defp ensure_user_default_caps(user_uri, admin_uri) do
    # Phase 9 PR-3 (SPEC v3 §4.5): default caps are workspace-scoped
    # — derive the bound user's workspace from their URI.
    workspace_uri = Ezagent.URI.entity_workspace_uri(to_uri(user_uri))

    workspace_uri
    |> session_participation_caps()
    |> Enum.reduce_while(:ok, fn cap, _acc ->
      case grant_cap(user_uri, admin_uri, cap) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # Build the per-action cap list a bound Feishu user needs to
  # participate in sessions across `workspace_uri`. Each cap is
  # action-specific so the §3.6.1(b) grant-time check passes when
  # dispatched under `system://feishu-binding-policy`. `instance: :any`
  # keeps the user's reach workspace-wide (matching the pre-SPEC
  # `default_caps/1` shape) — the workspace_uri axis is the structural
  # narrow.
  #
  # `granted_by` is the binding-policy principal (provenance + audit),
  # NOT the operator who triggered the bind. The operator's authority
  # for the bind action itself is gated upstream (`mix ezagent.feishu.bind`
  # admin-cap check); the cap-grant side-effect runs under the
  # binding-policy system principal per `system_principal/catalog.ex`.
  defp session_participation_caps(%URI{} = workspace_uri) do
    granted_by = Ezagent.SystemPrincipal.uri("feishu-binding-policy")
    granted_at = DateTime.utc_now()

    chat_caps =
      Enum.map(@session_chat_actions, fn action ->
        %Capability{
          kind: :session,
          behavior: Ezagent.Behavior.Chat,
          action: action,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: granted_by,
          granted_at: granted_at
        }
      end)

    publisher_caps =
      Enum.map(@session_publisher_actions, fn action ->
        %Capability{
          kind: :session,
          behavior: Ezagent.Behavior.Publisher.SessionImpl,
          action: action,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: granted_by,
          granted_at: granted_at
        }
      end)

    chat_caps ++ publisher_caps
  end

  defp grant_cap(user_uri, _admin_uri, %Capability{} = cap) do
    target = Ezagent.URI.with_action(Ezagent.URI.new!(to_str(user_uri)), :identity, :grant_cap)

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
  defp to_uri(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
