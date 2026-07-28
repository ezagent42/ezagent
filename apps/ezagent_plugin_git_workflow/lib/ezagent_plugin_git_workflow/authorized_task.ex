defmodule EzagentPluginGitWorkflow.AuthorizedTask do
  @moduledoc """
  The closed, credential-free value an `ExecutionSeam` backend returns from
  `authorize/2` and every `invoke/3` call carries (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.1, §3.2).

  §3.1 fixes the contents exactly: "a validated exact `GitTaskAccess` policy,
  task URI, and generation". This struct has those four fields and no others —
  no `caps`, no `cap`, no `ctx`, no `token`, no `invocation`, no free-form
  `metadata` map. That absence is the enforcement: **a struct with no place to
  put a credential cannot carry one**, so the seam contract cannot silently
  widen into a capability / `%Invocation{}` / token / raw-body leak the way a
  bare `term()` (what the seam typed this as before Slice P4a) could.

  ## Consistency, not just well-typedness

  `new/1` proves the four fields describe **one** authorization, not four
  independently plausible values:

    * `policy` round-trips through `Ezagent.Entity.GitTaskAccess.revalidate/1`
      — the same chokepoint the Git task-access action set
      (`apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`) runs
      before it touches anything authority-sensitive. A policy that would be
      rejected downstream is rejected here instead of travelling further;
    * `task_uri` and `generation` must equal the policy's own;
    * `task_access_uri` must equal `GitTaskAccess.uri_from_args(policy)` — the
      content-addressed receiver URI derived from the whole policy.

  So a caller cannot assemble an authorized task for one policy while naming a
  different task, a different generation, or a different task-access instance.

  ## Deliberately no redacting `Inspect`

  There is nothing secret in this struct, and a redacting `Inspect` would make
  a future leak *harder* to notice in test output rather than easier — the
  redaction would quietly hide whatever field someone later added.

  Nothing constructs an `AuthorizedTask` yet: the only shipping seam backend,
  `ExecutionSeam.Unavailable`, never returns `{:ok, _}`. Slice P4b builds the
  backend that does.
  """

  alias Ezagent.Entity.GitTaskAccess

  @fields [:policy, :task_access_uri, :task_uri, :generation]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          policy: GitTaskAccess.t(),
          task_access_uri: URI.t(),
          task_uri: URI.t(),
          generation: pos_integer()
        }

  @doc """
  Builds an authorized task from exactly `#{inspect(@fields)}`.

  Follows the shape `Ezagent.DomainGit.OperationContext.new/1` and
  `Ezagent.Entity.GitTaskAccess.new/1` already use in this domain: reject
  non-atom keys, reject any key outside the four, reject a missing key, then
  validate that the values are mutually consistent.
  """
  @spec new(term()) ::
          {:ok, t()}
          | {:error, :unknown_fields}
          | {:error, {:missing_field, atom()}}
          | {:error, {:invalid_field, atom()}}
  # `Map.fetch!/2` rather than `attrs.policy`, and a destructuring head on
  # `validate_coordinates/2` rather than `attrs.task_uri` — `validate_keys/1`
  # has already proven all four keys are present, and the plugin
  # workspace-locality scanner cannot type-prove a dot-access receiver, so it
  # would otherwise book four benign field reads as dynamic-receiver debt
  # (same fix as `Authorization.authorize_run/2` took on this branch).
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         {:ok, policy} <- validated_policy(Map.fetch!(attrs, :policy)),
         :ok <- validate_coordinates(attrs, policy) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :policy, policy))}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  # A non-atom key is by definition outside the four allowed atom keys, so it
  # takes the same answer rather than a separate one a caller would have to
  # branch on.
  defp validate_keys(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(&1 not in @fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(@fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      true ->
        :ok
    end
  end

  defp validated_policy(%GitTaskAccess{} = policy) do
    case GitTaskAccess.revalidate(policy) do
      {:ok, validated} -> {:ok, validated}
      {:error, _reason} -> {:error, {:invalid_field, :policy}}
    end
  end

  defp validated_policy(_policy), do: {:error, {:invalid_field, :policy}}

  # `uri_from_args/1` is only ever reached with an already-revalidated policy,
  # so its "invalid policy" raise is unreachable from here.
  defp validate_coordinates(
         %{task_uri: task_uri, generation: generation, task_access_uri: task_access_uri},
         %GitTaskAccess{task_uri: policy_task_uri, generation: policy_generation} = policy
       ) do
    checks = [
      task_uri: task_uri == policy_task_uri,
      generation: generation == policy_generation,
      task_access_uri: task_access_uri == GitTaskAccess.uri_from_args(policy)
    ]

    case Enum.find(checks, fn {_field, consistent?} -> not consistent? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
