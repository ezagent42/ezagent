defmodule EzagentPluginGitWorkflow.GitAdapterProbe do
  @moduledoc """
  Effect sentinel for Slice P4b's authorization-surface tests.

  Every callback reports to the process registered as `probe_name/0` BEFORE it
  produces a result, so a denial test can `refute_receive` on it and prove the
  denial happened ahead of any adapter effect — the same shape
  `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs` uses
  with its workspace probe.

  It is registered under its own provider id, so installing it never disturbs
  a globally registered real adapter the way replacing a registry singleton
  would.
  """

  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{ChangeRequest, Check, Review}

  @probe_name :git_p4b_adapter_probe
  @provider_adapter :"p4b-probe"
  @head_sha String.duplicate("c", 40)

  @doc "The registered name a test must claim to receive this probe's reports."
  def probe_name, do: @probe_name

  @doc "The `provider_adapter` atom a `TaskBinding`/policy must carry to reach this probe."
  def provider_adapter, do: @provider_adapter

  @doc "The `AdapterRegistry` provider id (the string form of `provider_adapter/0`)."
  def provider_id, do: Atom.to_string(@provider_adapter)

  @doc "The head SHA every change request this probe reports carries."
  def head_sha, do: @head_sha

  @impl true
  def resolve_repository(context, repository) do
    report(:resolve_repository, context)
    {:ok, repository}
  end

  @impl true
  def create_change_request(context, repository, changes, request) do
    report(:create_change_request, context)
    {:ok, change_request(repository, request.head_ref, length(changes))}
  end

  @impl true
  def read_change_request(context, repository, change_request_id) do
    report(:read_change_request, context)

    {:ok,
     %{
       change_request(repository, "task/p4b/read", 0)
       | external_id: change_request_id.external_id
     }}
  end

  @impl true
  def list_checks(context, _repository, commit_sha) do
    report(:list_checks, context)

    {:ok,
     [
       %Check{
         external_id: "p4b-check",
         name: "p4b/#{commit_sha.value}",
         status: :completed,
         conclusion: :succeeded,
         url: nil
       }
     ]}
  end

  @impl true
  def list_reviews(context, _repository, _change_request_id) do
    report(:list_reviews, context)

    {:ok,
     [
       %Review{
         external_id: "p4b-review",
         author_label: "P4b Reviewer",
         state: :approved,
         submitted_at: nil
       }
     ]}
  end

  defp change_request(repository, head_ref, change_count) do
    %ChangeRequest{
      external_id: "p4b-change-#{change_count}",
      url: URI.parse("https://git.example.test/p4b/changes/1"),
      head_ref: head_ref,
      head_sha: @head_sha,
      base_ref: repository.base_ref,
      state: :open
    }
  end

  defp report(action, context) do
    if owner = Process.whereis(@probe_name) do
      send(owner, {:git_p4b_adapter_call, action, context})
    end

    :ok
  end
end
