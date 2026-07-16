defmodule Ezagent.DomainGit.TestSupport.SynchronizedGitAdapterA do
  @moduledoc false
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterA, SynchronizedGitProbe}

  @impl true
  def resolve_repository(context, repository) do
    SynchronizedGitProbe.call("sync-a", :resolve_repository, context)
    FakeGitAdapterA.resolve_repository(context, repository)
  end

  @impl true
  def create_change_request(context, repository, changes, request) do
    owner = SynchronizedGitProbe.call("sync-a", :create_change_request, context)

    if request.expected_base_sha.value == String.duplicate("a", 40) do
      :ok = SynchronizedGitProbe.mutation(owner, "sync-a", :create_change_request)
      FakeGitAdapterA.create_change_request(context, repository, changes, request)
    else
      {:error, :stale_base}
    end
  end

  @impl true
  def read_change_request(context, repository, id),
    do: FakeGitAdapterA.read_change_request(context, repository, id)

  @impl true
  def list_checks(context, repository, sha),
    do: FakeGitAdapterA.list_checks(context, repository, sha)

  @impl true
  def list_reviews(context, repository, id),
    do: FakeGitAdapterA.list_reviews(context, repository, id)
end
