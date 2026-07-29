defmodule EzagentPluginGitWorkflow.PlanEE2ECase do
  @moduledoc """
  Setup for Slice P4e — design §8's local end-to-end acceptance run.

  Everything §8 lists as an ingredient is real except the provider itself:

  | §8 ingredient | here |
  |---|---|
  | fresh PostgreSQL test partition | `EzagentCore.DataCase`, `async: false` (shared sandbox) |
  | 临时本地 bare repository + 真实 task-worktree provision | `local_origin!/1` + the REAL `WorkspaceProvisionRegistry` implementation, reached through the action set |
  | execution backend | the REAL `ExecutionSeam.CapBacked` — see below |
  | GitHub App JWT / installation / Git Data / PR / checks / reviews | `EzagentPluginGitWorkflow.StubGitProvider` |
  | 真实 workflow store/CAS/restart reconciliation | `Store`, `StageRunner`, `Observation` |

  ## §8's "显式 test-authorized execution backend" is stale — read §3.4

  §8 was written 2026-07-25, when §3.1 made production a permanent dead end
  and a test double was the only way to get past `authorization_unavailable`.
  §3.4 (gaga, 2026-07-28) lifted that: `ExecutionSeam`'s `compile_env`
  default IS `CapBacked` now, and Slice P4b shipped it with its own
  adversarial suite. So this harness installs the REAL backend. An E2E on a
  test-authorized double would prove the pipeline works GIVEN authorization;
  on the real one it proves the pipeline works INCLUDING authorization —
  `authorize_receiver`, `action_allowed`, `validate_requested_head` and a
  real signed capability all run. What stays stubbed is GitHub, never the
  seam.

  ## Why the stub is a plug function and not `Req.Test`

  See `EzagentPluginGitWorkflow.StubGitProvider`. Short version: this app
  must not depend on the GitHub plugin (§3.2 + `architecture_test.exs`), and
  `:req` reaches it only through that plugin — so the stub is installed
  through the GitHub plugin's own documented `:adapter_req_opts` injection
  point, as data, without this app naming a single GitHub-plugin module.
  That is not a workaround for the boundary; it is the boundary being
  honoured. Every GitHub-side value in this harness travels as application
  env or as a URI, exactly as it would in production.

  ## The base commit is the SAME commit on both sides

  `local_origin!/1` builds a real bare repository, and the stub provider is
  seeded with THAT repository's `HEAD` sha and tree sha. So the base commit
  the provisioner checks out and the base commit the adapter verifies
  (`expected_base_sha`) are one commit, not two coincidentally-equal
  fixtures. A drift between them surfaces as `:base_sha_mismatch`, which is
  the real failure it would be in production.
  """

  use ExUnit.CaseTemplate

  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.StubGitProvider
  alias EzagentPluginGitWorkflow.Store

  # The setup is injected by the `using` block rather than declared as a
  # template `setup`, and the ORDER is load-bearing:
  # `ExUnit.CaseTemplate.__proxy__/2` registers a template's own `setup`
  # BEFORE the `using` block runs, so a template `setup` here would execute
  # before `EzagentCore.DataCase` had checked out a sandbox connection — and
  # this setup writes rows. Declaring it inside the block, after `use
  # EzagentCore.DataCase`, puts it in the right place.
  using do
    quote do
      use EzagentCore.DataCase, async: false

      import EzagentPluginGitWorkflow.PlanEE2ECase

      setup do
        EzagentPluginGitWorkflow.PlanEE2ECase.setup_e2e()
      end
    end
  end

  @doc false
  def setup_e2e do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "git-p4e-#{unique}")
    File.mkdir_p!(root)

    previous_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", root)

    # Registered BEFORE anything can fail. `EZAGENT_HOME` and the three
    # `:ezagent_plugin_github` keys are VM-GLOBAL: a setup that raises after
    # setting them and before registering their restore leaks them into every
    # test that follows, in this app and the next. Deleting a key that was
    # never set is a no-op, so registering first costs nothing.
    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)

      if is_nil(previous_home),
        do: System.delete_env("EZAGENT_HOME"),
        else: System.put_env("EZAGENT_HOME", previous_home)

      File.rm_rf!(root)
    end)

    origin = local_origin!(root)

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _req,
                                                                                      _pol ->
      %{remote_url: origin.path, allow_local_fixture: true}
    end)

    token = "ghs-P4E-INSTALLATION-TOKEN-#{unique}-MUST-NOT-LEAK"

    provider =
      ExUnit.Callbacks.start_supervised!(
        {StubGitProvider,
         repo: "acme/widgets",
         base_ref: "main",
         base_sha: origin.head_sha,
         base_tree_sha: origin.tree_sha,
         token: token,
         checks: [
           %{
             "id" => 9001,
             "name" => "ci/build",
             "status" => "completed",
             "conclusion" => "success",
             "details_url" => "https://git.example.test/checks/9001"
           }
         ],
         reviews: [
           %{
             "id" => 7001,
             "user" => %{"login" => "P4e Reviewer"},
             "state" => "APPROVED",
             "submitted_at" => "2026-07-28T09:00:00Z"
           }
         ]}
      )

    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, app_private_key_pem())

    # `retry: false` for the same reason `github_adapter_reconciliation_test.exs`
    # documents: Req's default `:safe_transient` retry re-issues 5xx/429 by
    # itself, which would silently absorb the fault injections this slice
    # exists to observe and inflate every request count.
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts,
      plug: StubGitProvider.plug(provider),
      retry: false
    )

    workspace = "git-p4e-#{unique}"

    binding =
      GitTaskAccessFixture.binding(%{
        workspace: workspace,
        provider_adapter: :github,
        provider_host: "github.com",
        external_id: "acme/widgets",
        owner_path: "acme",
        base_ref: "main",
        visibility: :public,
        allowed_head_namespace: "task/p4e/"
      })

    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: "task-p4e-#{unique}",
        source_task_uri: Ezagent.URI.resource(workspace, "task", "task-p4e"),
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, run} = Store.accept(intent)
    {:ok, policy} = PolicyDerivation.derive(run, binding)
    task_access_uri = GitTaskAccess.uri_from_args(policy)

    :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)

    # LIFO: this runs before the global-state restore above, so the Kind is
    # gone while its policy's registry entries are still meaningful.
    ExUnit.Callbacks.on_exit(fn -> TaskAccessSupervisor.teardown(task_access_uri) end)

    %{
      binding: binding,
      intent: intent,
      origin: origin,
      policy: policy,
      provider: provider,
      root: root,
      run: run,
      task_access_uri: task_access_uri,
      token: token,
      workspace: workspace
    }
  end

  # ---------------------------------------------------------------------------
  # The local bare repository
  # ---------------------------------------------------------------------------

  @doc """
  Builds a real bare repository with one commit on `main` and reports its
  path, head sha and tree sha.

  Shaped after `local_origin!/2` in
  `apps/ezagent_domain_workspace/test/.../change_collector_test.exs`, which
  is a PRIVATE function inside a test module in an app this one does not
  depend on — it cannot be called, only copied. It is copied rather than
  promoted to shared support because promoting it would put a
  `ezagent_domain_workspace` test-support module on this app's compile path,
  which is the dependency the design forbids. The two additions here are the
  head/tree shas, which the stub provider must be seeded with.
  """
  @spec local_origin!(String.t()) :: %{
          path: String.t(),
          head_sha: String.t(),
          tree_sha: String.t()
        }
  def local_origin!(root) do
    origin = Path.join(root, "origin-#{System.unique_integer([:positive])}.git")
    source = Path.join(root, "source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)

    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])

    %{
      path: origin,
      head_sha: source |> git!(["rev-parse", "HEAD"]) |> String.trim(),
      tree_sha: source |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    }
  end

  # Raises with the COMMAND and git's own output rather than letting a bare
  # `{output, 0} = ...` MatchError hide both. A fixture repository that fails
  # to build is the least interesting reason for this suite to be red, and it
  # must not cost anyone a debugging session to find that out.
  defp git!(cd, args) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        raise "git #{Enum.join(args, " ")} (cd: #{cd}) exited #{status}:\n#{output}"
    end
  end

  # ---------------------------------------------------------------------------
  # The scenario, as steps every file in this slice shares
  # ---------------------------------------------------------------------------

  @worker_file "notes.md"
  @worker_content "written by the task worker\n"

  @doc "The bounded UTF-8 content §8's step 4 has the worker write."
  @spec worker_content() :: String.t()
  def worker_content, do: @worker_content

  @doc "Performs the ONE stage the run owes, asserting it succeeded."
  @spec advance!(String.t()) :: EzagentPluginGitWorkflow.WorkflowRun.t()
  def advance!(run_id) do
    assert {:ok, run} = EzagentPluginGitWorkflow.StageRunner.advance(run_id)
    run
  end

  @doc """
  `accepted → authorized` through `Authorization.authorize_run/2` — the
  production entry point §8's "authorize test task" names, and the one §3.1
  requires to have zero side effects when it denies.
  """
  @spec authorize!(String.t(), EzagentPluginGitWorkflow.TaskBinding.t()) ::
          EzagentPluginGitWorkflow.WorkflowRun.t()
  def authorize!(run_id, binding) do
    {:ok, run} = Store.read_run(run_id)

    assert {:ok, %EzagentPluginGitWorkflow.WorkflowRun{status: "authorized"} = authorized} =
             EzagentPluginGitWorkflow.Authorization.authorize_run(run, binding)

    authorized
  end

  @doc """
  Carries a fresh run to `changes_ready` with one bounded UTF-8 file written
  into the provisioned worktree by a "worker" (a plain `File.write!/2`).

  The write is what makes §8's step 4 real: the collected change comes from a
  file that exists on disk, never from a hand-built `%FileChange{}`.
  """
  @spec to_changes_ready!(String.t(), EzagentPluginGitWorkflow.TaskBinding.t(), keyword()) :: :ok
  def to_changes_ready!(run_id, binding, opts \\ []) do
    authorize!(run_id, binding)
    assert %{status: "workspace_ready"} = advance!(run_id)

    write_worker_file!(
      run_id,
      Keyword.get(opts, :content, @worker_content),
      Keyword.get(opts, :name, @worker_file)
    )

    assert %{status: "changes_ready"} = advance!(run_id)
    :ok
  end

  @doc "Writes `content` into the run's provisioned worktree and returns the path."
  @spec write_worker_file!(String.t(), iodata(), String.t()) :: String.t()
  def write_worker_file!(run_id, content, name \\ @worker_file) do
    {:ok, %EzagentPluginGitWorkflow.WorkflowFacts{workspace_provision_id: provision_id}} =
      Store.read_facts(run_id)

    path = Path.join(worktree_path!(provision_id), name)
    File.write!(path, content)
    path
  end

  @doc """
  The worktree the provisioner really created for `provision_id`.

  Read with raw SQL rather than through
  `Ezagent.Workspace.TaskWorkspace.Store`: naming that module would put
  `ezagent_domain_workspace` on this app's compile path.
  """
  @spec worktree_path!(String.t()) :: String.t()
  def worktree_path!(provision_id) do
    %{rows: [[path]]} =
      EzagentCore.Repo.query!(
        "SELECT worktree_path FROM git_task_workspace_provisions WHERE provision_id = $1",
        [provision_id]
      )

    path
  end

  @doc """
  Rewinds a run's durable status without touching its facts.

  This is what a crash between "facts written" and "state CAS" leaves behind
  (design §6.2's fourth window), and it is also how §8's "重复完整执行两次"
  is expressed: the state machine has no legal edge back from a later state,
  so replaying the sequence means putting the run back where a crash would
  have left it. Written with SQL because it is deliberately NOT a transition
  the runner is allowed to make.
  """
  @spec rewind!(String.t(), String.t()) :: :ok
  def rewind!(run_id, status) do
    EzagentCore.Repo.query!("UPDATE git_workflow_runs SET status = $1 WHERE id = $2", [
      status,
      run_id
    ])

    :ok
  end

  @doc "Every string value in every row of the workflow's three tables."
  @spec all_persisted_strings() :: [String.t()]
  def all_persisted_strings do
    ~w(git_workflow_runs git_workflow_facts git_workflow_bindings git_task_workspace_provisions)
    |> Enum.flat_map(fn table ->
      %{rows: rows} = EzagentCore.Repo.query!("SELECT * FROM #{table}")
      rows |> List.flatten() |> Enum.filter(&is_binary/1)
    end)
  end

  @doc """
  Runs `fun` with a handler attached to every telemetry event any handler in
  this VM is subscribed to, plus the repo's query event, and returns what was
  emitted.

  The repo event is the load-bearing one for §8's leak claim: it carries the
  SQL and every bound parameter, so a token that reached any column would
  appear there whether or not the write also landed.
  """
  @spec capture_telemetry((-> result)) :: {result, [term()]} when result: term()
  def capture_telemetry(fun) do
    owner = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    events =
      [[:ezagent_core, :repo, :query] | Enum.map(:telemetry.list_handlers([]), & &1.event_name)]
      |> Enum.uniq()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(owner, {:p4e_telemetry, event, measurements, metadata})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)
    {result, drain_telemetry([])}
  end

  defp drain_telemetry(acc) do
    receive do
      {:p4e_telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub App key
  # ---------------------------------------------------------------------------

  # Generated ONCE per VM: `:public_key.generate_key/1` for a 2048-bit RSA key
  # costs ~100ms, and every test in this file signs a JWT with it. Same shape
  # as `EzagentPluginGithub.TestHelpers.test_private_key_pem/0`, which this app
  # cannot call for the dependency reason in the moduledoc.
  defp app_private_key_pem do
    case :persistent_term.get({__MODULE__, :app_key}, nil) do
      nil ->
        key = :public_key.generate_key({:rsa, 2048, 65_537})
        pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
        :persistent_term.put({__MODULE__, :app_key}, pem)
        pem

      pem ->
        pem
    end
  end
end
