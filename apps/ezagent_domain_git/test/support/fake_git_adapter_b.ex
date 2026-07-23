defmodule Ezagent.DomainGit.TestSupport.FakeGitAdapterB do
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{Check, Review}
  alias Ezagent.DomainGit.TestSupport.FakeGitAdapterA, as: Shared

  @impl true
  def resolve_repository(context, repository),
    do: Shared.respond(context, fn -> {:ok, %{repository | external_id: "fake-b"}} end)

  @impl true
  def create_change_request(context, repository, _changes, request),
    do:
      Shared.respond(context, fn ->
        {:ok, Shared.change_request("fake-b", repository, request)}
      end)

  @impl true
  def read_change_request(context, repository, change_request_id),
    do:
      Shared.respond(context, fn ->
        request = %{head_ref: "task/fake-b"}
        change_request = Shared.change_request("fake-b", repository, request)
        {:ok, %{change_request | external_id: change_request_id.external_id}}
      end)

  @impl true
  def list_checks(context, _repository, commit_sha),
    do:
      Shared.respond(context, fn ->
        {:ok,
         [
           %Check{
             external_id: "fake-b-check",
             name: "fake-b/#{commit_sha.value}",
             status: :in_progress,
             conclusion: nil,
             url: nil
           }
         ]}
      end)

  @impl true
  def list_reviews(context, _repository, _change_request_id),
    do:
      Shared.respond(context, fn ->
        {:ok,
         [
           %Review{
             external_id: "fake-b-review",
             author_label: "Fake B Reviewer",
             state: :commented,
             submitted_at: nil
           }
         ]}
      end)
end
