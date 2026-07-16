defmodule Ezagent.DomainGit.TestSupport.FakeGitAdapterA do
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{ChangeRequest, Check, Review}

  @errors [
    :provider_account_not_connected,
    :credential_backend_unavailable,
    :repository_not_found,
    :repository_read_denied,
    :repository_write_denied,
    :private_checkout_not_supported,
    :base_ref_not_found,
    :base_sha_mismatch,
    :invalid_ref,
    :invalid_file_change,
    :change_limit_exceeded,
    :change_request_conflict,
    :checks_unavailable,
    :provider_unavailable,
    :authentication_rejected
  ]

  @impl true
  def resolve_repository(context, repository),
    do: respond(context, fn -> {:ok, %{repository | external_id: "fake-a"}} end)

  @impl true
  def create_change_request(context, repository, _changes, request),
    do: respond(context, fn -> {:ok, change_request("fake-a", repository, request)} end)

  @impl true
  def read_change_request(context, repository, change_request_id),
    do:
      respond(context, fn ->
        request = %{head_ref: "task/fake-a"}
        change_request = change_request("fake-a", repository, request)
        {:ok, %{change_request | external_id: change_request_id.external_id}}
      end)

  @impl true
  def list_checks(context, _repository, commit_sha),
    do:
      respond(context, fn ->
        {:ok,
         [
           %Check{
             external_id: "fake-a-check",
             name: "fake-a/#{commit_sha.value}",
             status: :completed,
             conclusion: :succeeded,
             url: nil
           }
         ]}
      end)

  @impl true
  def list_reviews(context, _repository, _change_request_id),
    do:
      respond(context, fn ->
        {:ok,
         [
           %Review{
             external_id: "fake-a-review",
             author_label: "Fake A Reviewer",
             state: :approved,
             submitted_at: nil
           }
         ]}
      end)

  @doc false
  def respond(%{idempotency_key: key}, success) do
    case error_from_key(key) do
      nil -> success.()
      error -> {:error, error}
    end
  end

  @doc false
  def change_request(provider, repository, request) do
    %ChangeRequest{
      external_id: provider <> "-change",
      url: URI.parse("https://git.example.test/" <> provider <> "/changes/1"),
      head_ref: request.head_ref,
      head_sha: String.duplicate("b", 40),
      base_ref: repository.base_ref,
      state: :open
    }
  end

  defp error_from_key("error:provider_request_failed:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      ["create_change_request", status] ->
        case Integer.parse(status) do
          {status, ""} when status > 0 ->
            {:provider_request_failed, :create_change_request, status}

          _other ->
            nil
        end

      _other ->
        nil
    end
  end

  defp error_from_key("error:" <> encoded),
    do: Enum.find(@errors, &(Atom.to_string(&1) == encoded))

  defp error_from_key(_key), do: nil
end
