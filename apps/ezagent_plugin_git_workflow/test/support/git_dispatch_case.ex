defmodule EzagentPluginGitWorkflow.GitDispatchCase do
  @moduledoc """
  Shared setup for the Slice P4b tests that go through the REAL Kind runtime.

  It builds the two durable rows, derives the policy through
  `PolicyDerivation` (not by hand — the point of these tests is the pipeline
  the backend actually runs), registers the adapter probe under its own
  provider id, and claims the probe's registered name for the test process so
  `assert_receive` / `refute_receive` observe adapter effects.

  Each test gets its OWN workspace, so its task-access URI — a digest of the
  whole policy — is unique and cannot collide with a Kind another test left
  registered.
  """

  use ExUnit.CaseTemplate

  alias Ezagent.DomainGit.AdapterRegistry
  alias Ezagent.DomainGit.CommitSha
  alias Ezagent.DomainGit.CreateChangeRequest
  alias Ezagent.DomainGit.FileChange
  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.GitAdapterProbe
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.PolicyDerivation

  using do
    quote do
      use EzagentCore.DataCase, async: false

      import EzagentPluginGitWorkflow.GitDispatchCase
    end
  end

  setup do
    assert Process.whereis(AdapterRegistry),
           "Ezagent.DomainGit.AdapterRegistry is not running — the whole umbrella must boot"

    claim_probe_name()
    :ok = register_probe_adapter()

    workspace = "git-p4b-" <> owner_id(self())

    binding =
      GitTaskAccessFixture.binding(%{
        workspace: workspace,
        provider_adapter: GitAdapterProbe.provider_adapter()
      })

    run = GitTaskAccessFixture.run(%{workspace: workspace})

    {:ok, policy} = PolicyDerivation.derive(run, binding)
    task_access_uri = GitTaskAccess.uri_from_args(policy)

    on_exit(fn -> TaskAccessSupervisor.teardown(task_access_uri) end)

    %{
      workspace: workspace,
      binding: binding,
      run: run,
      policy: policy,
      task_access_uri: task_access_uri
    }
  end

  @doc "Valid `create_change_request` arguments for `policy` (head ref must be the allowed one)."
  def create_change_request_args(policy) do
    {:ok, change} = FileChange.new(%{path: "README.md", operation: :upsert, content: "ok"})

    {:ok, request} =
      CreateChangeRequest.new(%{
        title: "Slice P4b",
        body: "authorization surface",
        head_ref: policy.allowed_head_ref,
        expected_base_sha: %CommitSha{value: String.duplicate("a", 40)},
        commit_date: ~U[2026-07-28 09:30:00Z]
      })

    %{repository: policy.repository, changes: [change], request: request}
  end

  @doc "The action-bearing target URI the seam backend builds for `action`."
  def action_target(task_access_uri, action),
    do: Ezagent.URI.with_action(task_access_uri, :git_task_access, action)

  @doc "The canonical admin — the ISSUANCE ANCHOR, never a principal."
  def admin_uri, do: Ezagent.URI.user(:system, :admin)

  @doc """
  Starts the task-access Kind, exactly as `CapBacked.invoke/3` does first.

  A cap cannot be minted for a target that is not live —
  `Cap.issue_for_action/3` resolves the required shape from the RUNNING
  instance's own declaration — so a test that hand-builds an invocation must
  start the Kind the same way the backend does.
  """
  def start_task_access(policy) do
    {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    :ok
  end

  @doc """
  Mints a real, signed, current capability for `grantee_uri` against `target`.

  Same call the seam backend makes, with the grantee as the only variable —
  which is what lets a negative test hand an ATTACKER a genuinely valid cap
  instead of a forged one.
  """
  def mint_cap(grantee_uri, target) do
    {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, admin_uri()}, grantee_uri, target)
    cap
  end

  @doc """
  The `%Ezagent.Invocation{}` the seam backend builds, with every field a
  negative test might need to vary exposed as an option.
  """
  def backend_shaped_invocation(target, args, opts) do
    caller = Keyword.fetch!(opts, :caller)

    %Ezagent.Invocation{
      target: Keyword.get(opts, :target, target),
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        authenticated_principal: Keyword.get(opts, :authenticated_principal, caller),
        caps: MapSet.new(Keyword.fetch!(opts, :caps)),
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    }
  end

  defp claim_probe_name do
    name = GitAdapterProbe.probe_name()

    # These suites are `async: false`, so nothing else holds the name; a
    # leftover registration from a crashed prior test is cleared rather than
    # crashing this setup with a bare `ArgumentError`.
    case Process.whereis(name) do
      nil -> :ok
      pid when pid == self() -> Process.unregister(name)
      _other -> Process.unregister(name)
    end

    Process.register(self(), name)
  end

  defp register_probe_adapter do
    case AdapterRegistry.register(GitAdapterProbe.provider_id(), GitAdapterProbe) do
      :ok -> :ok
      {:ok, :already_registered} -> :ok
    end
  end

  defp owner_id(pid) do
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.replace(".", "-")
  end
end
