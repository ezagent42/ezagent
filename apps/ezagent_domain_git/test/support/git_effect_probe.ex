defmodule Ezagent.DomainGit.TestSupport.GitEffectProbe do
  @moduledoc false

  use Agent

  def start_link(owner) do
    Agent.start_link(fn -> %{owner: owner, ref: make_ref(), block?: false} end, name: __MODULE__)
  end

  def ref, do: Agent.get(__MODULE__, & &1.ref)
  def block_next, do: Agent.update(__MODULE__, &%{&1 | block?: true})

  def trip(operation, context) do
    %{owner: owner, ref: ref, block?: block?} = Agent.get(__MODULE__, & &1)

    Enum.each([:adapter, :http, :secret, :filesystem], fn sentinel ->
      send(owner, {:git_probe, ref, sentinel, operation, context})
    end)

    if block? do
      Agent.update(__MODULE__, &%{&1 | block?: false})
      send(owner, {:git_probe, ref, :callback_waiting, self()})

      receive do
        {:git_probe_release, ^ref} -> :ok
      end
    else
      :ok
    end
  end

  def mutation(operation) do
    %{owner: owner, ref: ref} = Agent.get(__MODULE__, & &1)
    send(owner, {:git_probe, ref, :mutation, operation})
    :ok
  end
end

defmodule Ezagent.DomainGit.TestSupport.ProbeGitAdapterA do
  @moduledoc false
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterA, GitEffectProbe}

  @impl true
  def resolve_repository(context, repository) do
    :ok = GitEffectProbe.trip(:resolve_repository, context)
    FakeGitAdapterA.resolve_repository(context, repository)
  end

  @impl true
  def create_change_request(context, repository, changes, request) do
    :ok = GitEffectProbe.trip(:create_change_request, context)

    if request.expected_base_sha.value == String.duplicate("a", 40) do
      :ok = GitEffectProbe.mutation(:create_change_request)
      FakeGitAdapterA.create_change_request(context, repository, changes, request)
    else
      {:error, :stale_base}
    end
  end

  @impl true
  def read_change_request(context, repository, id) do
    :ok = GitEffectProbe.trip(:read_change_request, context)
    FakeGitAdapterA.read_change_request(context, repository, id)
  end

  @impl true
  def list_checks(context, repository, sha) do
    :ok = GitEffectProbe.trip(:list_checks, context)
    FakeGitAdapterA.list_checks(context, repository, sha)
  end

  @impl true
  def list_reviews(context, repository, id) do
    :ok = GitEffectProbe.trip(:list_reviews, context)
    FakeGitAdapterA.list_reviews(context, repository, id)
  end
end

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
