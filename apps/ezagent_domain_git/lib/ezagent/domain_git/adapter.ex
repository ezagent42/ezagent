defmodule Ezagent.DomainGit.Adapter do
  @moduledoc """
  Provider-neutral contract implemented by Git provider adapters.

  Callers provide only validated `Ezagent.DomainGit` values. Provider adapters
  normalize provider responses and failures into the closed domain result shapes.
  """

  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    Check,
    CommitSha,
    CreateChangeRequest,
    Error,
    FileChange,
    OperationContext,
    RepositoryRef,
    Review
  }

  @type action ::
          :resolve_repository
          | :create_change_request
          | :read_change_request
          | :list_checks
          | :list_reviews

  @callback resolve_repository(OperationContext.t(), RepositoryRef.t()) ::
              {:ok, RepositoryRef.t()} | {:error, Error.t()}

  @callback create_change_request(
              OperationContext.t(),
              RepositoryRef.t(),
              [FileChange.t()],
              CreateChangeRequest.t()
            ) :: {:ok, ChangeRequest.t()} | {:error, Error.t()}

  @callback read_change_request(
              OperationContext.t(),
              RepositoryRef.t(),
              ChangeRequestId.t()
            ) :: {:ok, ChangeRequest.t()} | {:error, Error.t()}

  @callback list_checks(OperationContext.t(), RepositoryRef.t(), CommitSha.t()) ::
              {:ok, [Check.t()]} | {:error, Error.t()}

  @callback list_reviews(OperationContext.t(), RepositoryRef.t(), ChangeRequestId.t()) ::
              {:ok, [Review.t()]} | {:error, Error.t()}
end
