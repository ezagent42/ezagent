defmodule Ezagent.DomainGit.TestSupport.SynchronizedGitAdapterB do
  @moduledoc false
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterB, SynchronizedGitProbe}

  @impl true
  def resolve_repository(context, repository) do
    SynchronizedGitProbe.call("sync-b", :resolve_repository, context)
    FakeGitAdapterB.resolve_repository(context, repository)
  end

  @impl true
  def create_change_request(context, repository, changes, request) do
    owner = SynchronizedGitProbe.call("sync-b", :create_change_request, context)

    if request.expected_base_sha.value == String.duplicate("a", 40) do
      :ok = SynchronizedGitProbe.mutation(owner, "sync-b", :create_change_request)
      FakeGitAdapterB.create_change_request(context, repository, changes, request)
    else
      {:error, :stale_base}
    end
  end

  @impl true
  def read_change_request(context, repository, id),
    do: FakeGitAdapterB.read_change_request(context, repository, id)

  @impl true
  def list_checks(context, repository, sha),
    do: FakeGitAdapterB.list_checks(context, repository, sha)

  @impl true
  def list_reviews(context, repository, id),
    do: FakeGitAdapterB.list_reviews(context, repository, id)
end
