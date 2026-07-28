defmodule EzagentPluginGitWorkflow.ExecutionSeam.CapBacked do
  @moduledoc """
  The real `ExecutionSeam` backend (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.4 — the 2026-07-28 decision to lift the permanent fail-closed default).

  It obtains authorization through main's canonical pattern, the one written
  identically at ~62 lib sites (`retirement_sweeper.ex:99-118` is the
  reference): read the principal out of a durable row, use the canonical admin
  ONLY as the issuance anchor, mint an exact per-action capability, dispatch.

  ## Two layers, and what each one is worth (§3.4.1)

  | layer | question it answers | enforced by |
  |---|---|---|
  | capability | is this legitimate framework-internal traffic? | `Ezagent.Cap.Authorize.authorize/3` — principal loaded independently, candidate verified against the target's CURRENT authority row, shape match |
  | `GitTaskAccess` policy | may THIS grantee do THIS action to THIS repository? | `authorize_receiver` + `action_allowed` + `validate_task_coordinates` + `validate_requested_head`, all inside the Git task-access action set |

  The capability is minted by this code, so it does **not** represent an
  operator having authorized this workflow. Git Provider's real business
  authorization is the second row: durable, per-task, naming the grantee, the
  permitted actions and the permitted head ref. This backend's correctness
  therefore rests on `PolicyDerivation` computing the right principal — which
  is why that derivation reads columns and never guesses.

  ## `authorize/2` answers a question; it does not begin work

  Zero side effects on EVERY path, the success path included: no Kind is
  started, no capability minted, no dispatch issued, no row written. §3.1
  requires a denying backend to have done nothing, and the cheapest way to be
  sure of that is for the deciding function to be incapable of doing anything.
  Work starts in `invoke/3`.

  ## What may not appear here

    * **No hand-built capability.** `Ezagent.Cap.issue_for_action/3` derives
      the requested shape from the target Kind's OWN declaration
      (`Cap.Verifier.required_cap/4`), so §3.4.2's "no `:any` dimension" is
      structural: there is no argument through which a wildcard could be
      introduced. `Capability.cap/5` + `Cap.issue/3` would hand that freedom
      back, so they are gated out by `architecture_test.exs`.
    * **The admin is never the principal.** `{:admin, ...}` is the issuance
      anchor and appears in exactly one argument position. `ctx.caller` and
      `ctx.authenticated_principal` are both the policy's grantee.
    * **`ctx.caps` never leaves this module.** It is built inside `invoke/3`,
      travels with one `%Ezagent.Invocation{}`, and dies with the dispatch —
      never reaching a workflow row, event, log line or error term (§3.2).
    * **One cap per invocation, never cached.** A cached cap is the
      stale-artifact class §3.4.1 warns about, and a cap minted for action A
      would not match action B anyway — it would fail closed at the shape
      gate, which is a confusing way to learn you cached something.

  ## Every failure leaves as a stable blocker code

  A raw dispatch, supervisor or issuance error term must not escape: §7.1
  forbids provider-shaped detail in presentation, and `Blocker.from_error/1`
  is total, so normalizing here costs nothing and closes the leak by
  construction.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Invocation
  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.Blocker
  alias EzagentPluginGitWorkflow.PolicyDerivation

  @impl true
  def authorize(run, binding) do
    case PolicyDerivation.derive(run, binding) do
      {:ok, policy} -> authorized_task(policy)
      # The derivation's finer reason is dropped rather than forwarded: the
      # seam contract (§3.1) has exactly two denial atoms, every derivation
      # failure is deterministic, and an error term that echoed the binding or
      # the policy would be the §3.2 leak this seam exists to prevent.
      {:error, _reason} -> {:error, :not_authorized}
    end
  end

  @impl true
  def invoke(
        %AuthorizedTask{
          policy: %GitTaskAccess{grantee_uri: grantee_uri} = policy,
          task_access_uri: task_access_uri
        },
        action,
        typed_args
      ) do
    action_target = action_target(task_access_uri, action)

    with {:ok, _pid} <- TaskAccessSupervisor.ensure_started(policy),
         {:ok, cap} <- mint(grantee_uri, action_target) do
      dispatch(action_target, grantee_uri, cap, typed_args)
    else
      {:error, reason} -> {:error, Blocker.from_error(reason)}
    end
  end

  # `policy` is destructured all the way down to `task_uri`/`generation`
  # rather than read with `policy.task_uri`: the plugin workspace-locality
  # scanner cannot type-prove a dot-access receiver, so each field read would
  # otherwise be booked as dynamic-receiver debt (the same fix
  # `AuthorizedTask.new/1` took on this branch).
  defp authorized_task(%GitTaskAccess{task_uri: task_uri, generation: generation} = policy) do
    case AuthorizedTask.new(%{
           policy: policy,
           task_access_uri: GitTaskAccess.uri_from_args(policy),
           task_uri: task_uri,
           generation: generation
         }) do
      {:ok, task} -> {:ok, task}
      {:error, _reason} -> {:error, :not_authorized}
    end
  end

  defp action_target(task_access_uri, action),
    do: Ezagent.URI.with_action(task_access_uri, :git_task_access, action)

  # The canonical admin is spelled the way `Ezagent.Cap` itself spells it
  # (`cap.ex:412`, `cap.ex:476`) rather than through
  # `Ezagent.Entity.User.admin_uri/0`, which would make this dormant plugin
  # depend on `ezagent_domain_identity` for a single constant. It is the
  # ISSUANCE ANCHOR: `Cap.issue_for_action/3` takes the grantee as a separate
  # argument, and that grantee is the policy's, never this value.
  defp mint(grantee_uri, action_target) do
    Ezagent.Cap.issue_for_action(
      {:admin, Ezagent.URI.user(:system, :admin)},
      grantee_uri,
      action_target
    )
  end

  defp dispatch(action_target, grantee_uri, cap, typed_args) do
    %Invocation{
      target: action_target,
      mode: :call,
      args: typed_args,
      ctx: %{
        caller: grantee_uri,
        authenticated_principal: grantee_uri,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    }
    |> Invocation.dispatch()
    |> normalize()
  end

  defp normalize({:ok, result}), do: {:ok, result}
  defp normalize({:error, reason}), do: {:error, Blocker.from_error(reason)}

  # A `:call` dispatch returns a two-tuple today; a third shape would be a
  # contract change, and `:internal_error` (terminal) surfaces it to an
  # operator instead of letting it pass through as a success.
  defp normalize(other), do: {:error, Blocker.from_error(other)}
end
