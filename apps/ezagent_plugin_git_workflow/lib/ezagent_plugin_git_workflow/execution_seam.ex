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

  ## Provisional `term()` typing (deferred to Slice P4)

  `authorized_task`, `action`, `typed_args`, and `typed_result` are all
  `term()` today. Nothing constructs an `authorized_task` yet — the only
  shipping implementation, `Unavailable`, never returns `{:ok, _}` — so
  there is nothing to constrain. When a real backend first constructs an
  authorized task (Slice P4), these types MUST be tightened to a closed,
  credential-free shape (e.g. an opaque `%AuthorizedTask{}` with a
  validating constructor) so the contract cannot silently widen to permit
  a capability / `%Invocation{}` / token / raw-body leak through this seam.

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

  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @type authorized_task :: term()
  @type action :: atom()
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
end
