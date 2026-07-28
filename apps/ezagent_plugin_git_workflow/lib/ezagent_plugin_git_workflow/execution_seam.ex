defmodule EzagentPluginGitWorkflow.ExecutionSeam do
  @moduledoc """
  Fail-closed authorization/execution seam — the ONLY internal chokepoint
  the workflow depends on to obtain an authorized task and invoke a
  provider-neutral action against it (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.1).

  `authorized_task` must encapsulate only a validated exact `GitTaskAccess`
  policy, task URI, and generation. It must NEVER carry a raw cap, an
  `%Invocation{}`, `ctx.caps`, a GitHub token, or any caller-supplied
  credential (§3.2).

  ## Why `typed_args`/`typed_result` stay `term()` (Slice P4a)

  `authorized_task` and `action` are now closed: the former is
  `EzagentPluginGitWorkflow.AuthorizedTask`, a struct with exactly four
  fields and no place to put a credential; the latter is the eight-action
  vocabulary `Ezagent.Entity.GitTaskAccess` declares. Both are enforced at
  runtime by `invoke/3`'s head, not merely documented in a typespec.

  `typed_args` and `typed_result` remain `term()` deliberately. Their
  per-action shape is already gated **structurally** downstream: the Git
  task-access action set
  (`apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`)
  matches every incoming arg map against a per-action `@allowed_keys`
  whitelist and rejects any key outside that action's list, and
  `Ezagent.Entity.GitTaskAccess.validate_invocation/2` additionally rejects
  any attempt to restate a policy-owned coordinate. Combined with
  `%AuthorizedTask{}` having no credential field, there is no place in this
  contract for a cap, an `%Invocation{}`, or a token to ride.

  What is deliberately NOT added here is a seam-level blacklist of
  forbidden arg-key spellings. A blacklist of names is exactly the kind of
  guard this project has repeatedly found does not hold — the next leak
  simply picks a name that is not on the list. The enforceable property is
  the downstream whitelist plus the closed struct, so that is what this
  seam relies on.

  ## Backend selection is compile-time, not runtime (hardwired)

  `implementation/0` resolves via `Application.compile_env/3`, captured
  once into a module attribute when this module compiles. This is
  deliberate and load-bearing: real authorization does not exist on the
  project's main branch yet, so until it lands, this seam must be a
  genuine dead end in production — not a value that release config,
  `sys.config`, `Application.put_env/3`, `Application.put_all_env/2`,
  `:application.set_env/3`, a remote IEx/RPC session, or any other
  in-VM caller could flip to something permissive. Because the value is
  baked in at compile time, none of those runtime mutation paths can
  change what this function returns after the app compiles — see
  `architecture_test.exs` (`ExecutionSeamTest` proves the same for the
  in-process mutation vectors directly).

  Production and dev config never set `:execution_seam` (enforced by
  `architecture_test.exs`), so both compile to
  `EzagentPluginGitWorkflow.ExecutionSeam.Unavailable` — the fail-closed
  backend that always returns `{:error, :authorization_unavailable}` and
  performs zero workspace/filesystem/provider/Agent side effects.

  Only `config/test.exs` names a different module, and even then it names
  a **test-build-only delegator**
  (`EzagentPluginGitWorkflow.ExecutionSeamTestDelegate`, compiled only
  under `MIX_ENV=test` via `elixirc_paths`) rather than a real backend.
  The delegator resolves the actual per-test backend from **process-local**
  state at call time, so a test injecting a fake (e.g. `FakeExecutionSeam`)
  only affects its own process and can never leak across tests or exist in
  a production build.
  """

  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  # The exact vocabulary `Ezagent.Entity.GitTaskAccess` declares in its own
  # `@actions`, and that its action set exposes. Restated here rather than read
  # from that module because it is a compile-time guard list: `action in
  # @actions` must be expanded at compile time, and a remote call cannot appear
  # in a guard.
  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace,
    :collect_workspace_changes
  ]

  @type authorized_task :: AuthorizedTask.t()
  @type action ::
          :resolve_repository
          | :create_change_request
          | :read_change_request
          | :list_checks
          | :list_reviews
          | :provision_workspace
          | :cleanup_workspace
          | :collect_workspace_changes
  @type typed_args :: term()
  @type typed_result :: term()

  @callback authorize(WorkflowRun.t(), TaskBinding.t()) ::
              {:ok, authorized_task()}
              | {:error, :authorization_unavailable}
              | {:error, :not_authorized}

  @callback invoke(authorized_task(), action(), typed_args()) ::
              {:ok, typed_result()} | {:error, term()}

  # Compile-time only — see moduledoc. Production/dev config never set this
  # key (architecture_test.exs enforces it), so both compile to Unavailable.
  # A runtime Application.put_env/put_all_env/:application.set_env call
  # AFTER this module compiles cannot change @backend — it is baked in.
  @backend Application.compile_env(
             :ezagent_plugin_git_workflow,
             :execution_seam,
             __MODULE__.Unavailable
           )

  @doc "Resolves the compile-time-selected seam implementation. Defaults to the fail-closed backend."
  @spec implementation() :: module()
  def implementation, do: @backend

  @doc """
  Authorizes `run` against `binding` through the compile-time-selected seam.

  This is the single call site that dispatches to `@backend` — callers
  (e.g. `Authorization.authorize_run/2`) invoke this static remote function
  instead of resolving `implementation/0` and calling the resulting module
  themselves, so the dynamic-dispatch indirection this seam requires (see
  moduledoc) is concentrated in one place rather than repeated at every
  call site.
  """
  @spec authorize(WorkflowRun.t(), TaskBinding.t()) ::
          {:ok, authorized_task()}
          | {:error, :authorization_unavailable}
          | {:error, :not_authorized}
  def authorize(run, binding), do: @backend.authorize(run, binding)

  @doc """
  Invokes `action` against an already-authorized task through the
  compile-time-selected seam.

  Like `authorize/2`, this is the single call site that dispatches to
  `@backend`, so the dynamic-dispatch indirection stays concentrated in one
  module instead of spreading to every stage.

  Both parts of the head are load-bearing, not decoration:

    * `%AuthorizedTask{}` — a raw map, a bare `%Ezagent.Entity.GitTaskAccess{}`
      policy, or anything else a caller assembled by hand must never reach a
      backend. Only the validating constructor produces this struct.
    * `action in @actions` — the vocabulary is closed at the seam, so a
      backend never has to decide what an unknown action means.

  A call that matches neither raises `FunctionClauseError`. That is the
  intended failure: it fails closed and LOUD. Returning `{:error, _}` would
  let a runner log the tuple and carry on as if a legitimate refusal had
  occurred, which is exactly how a malformed authorization slips through.
  """
  @spec invoke(AuthorizedTask.t(), action(), typed_args()) ::
          {:ok, typed_result()} | {:error, term()}
  def invoke(%AuthorizedTask{} = authorized_task, action, typed_args)
      when action in @actions,
      do: @backend.invoke(authorized_task, action, typed_args)
end
