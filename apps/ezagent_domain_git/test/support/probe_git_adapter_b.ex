defmodule Ezagent.DomainGit.TestSupport.ProbeGitAdapterB do
  @moduledoc false
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterB, GitEffectProbe}

  @impl true
  def resolve_repository(context, repository) do
    :ok = GitEffectProbe.trip(:resolve_repository, context)
    FakeGitAdapterB.resolve_repository(context, repository)
  end

  @impl true
  def create_change_request(context, repository, changes, request) do
    :ok = GitEffectProbe.trip(:create_change_request, context)

    if request.expected_base_sha.value == String.duplicate("a", 40) do
      :ok = GitEffectProbe.mutation(:create_change_request)
      FakeGitAdapterB.create_change_request(context, repository, changes, request)
    else
      {:error, :stale_base}
    end
  end

  @impl true
  def read_change_request(context, repository, id) do
    :ok = GitEffectProbe.trip(:read_change_request, context)
    FakeGitAdapterB.read_change_request(context, repository, id)
  end

  @impl true
  def list_checks(context, repository, sha) do
    :ok = GitEffectProbe.trip(:list_checks, context)
    FakeGitAdapterB.list_checks(context, repository, sha)
  end

  @impl true
  def list_reviews(context, repository, id) do
    :ok = GitEffectProbe.trip(:list_reviews, context)
    FakeGitAdapterB.list_reviews(context, repository, id)
  end
end
