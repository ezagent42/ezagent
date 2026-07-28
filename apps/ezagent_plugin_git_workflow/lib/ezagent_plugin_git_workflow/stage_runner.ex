defmodule EzagentPluginGitWorkflow.StageRunner do
  @moduledoc """
  Drives one workflow run from `authorized` to `pr_open` — workspace →
  changes → provider (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.4 state machine, §6.1 first execution, §6.2 crash/retry, §7.2 retry
  policy).

  ## A plain module, one stage per call

  No GenServer, no supervision child, no polling loop. `advance/2` performs
  EXACTLY ONE stage and returns; crash recovery is calling it again. That is
  not minimalism for its own sake — it makes "resume" and "first run" the same
  code path, so the resumed path cannot rot for lack of a caller, and it keeps
  every stage independently testable without a process to arrange around it.

  The runner never calls a port or an adapter. Every stage goes through
  `EzagentPluginGitWorkflow.ExecutionSeam`, which resolves to the
  compile-time-selected backend and reaches the Git task-access action set
  through real dispatch.

  ## The stage table

  | from → to | action(s) invoked | facts written |
  |---|---|---|
  | `authorized` → `workspace_ready` | `:provision_workspace` | `workspace_provision_id`, `expected_base_sha` |
  | `workspace_ready` → `changes_ready` | `:collect_workspace_changes` | `change_digest` |
  | `changes_ready` → `pr_open` | `:collect_workspace_changes`, then `:create_change_request` | `deterministic_head_ref` (BEFORE the call), then `change_request_*` + `head_sha` |

  `expected_base_sha` is the provisioner's `resolved_base_commit`. That is the
  semantically right source rather than a convenient one: the collected changes
  are relative to THAT checkout, so it is exactly the base the change request
  must apply to. No action in the frozen vocabulary (design §4.3) returns a
  base SHA any other way, and none is added.

  The provisioner's ready result also carries a `start_token`. It is never
  bound, never persisted, never logged and never echoed into an error: the
  success clause destructures only the three fields it needs, and the fallback
  clause drops the whole map rather than reporting it.

  ## Why `changes_ready` re-collects

  §5.3 stores the change DIGEST, never file contents, so a run resuming at
  `changes_ready` has no change list in hand — it must ask for one again.
  Collection is a read, so repeating it is free; what is NOT free is silently
  committing a different tree than the one the run recorded. §6.1's 2026-07-27
  correction makes the provider-side commit a pure function of its inputs so a
  retry reproduces the same sha, and the change list IS the tree. The
  re-collected digest is therefore compared against the recorded fact, and a
  disagreement stops the run at `blocked: change_digest_mismatch` instead of
  producing a second, different commit.

  ## `change_digest` — the exact hash input

  `change_digest/1` is `"sha256:" <> lowercase_hex(sha256(input))` where the
  input is, in order:

      framed("gitworkflow.change_digest.v1")
      then, for each change, framed(path) framed(operation) framed(content)

  and `framed(value)` is `byte_size(value)` in decimal, `":"`, then the bytes —
  a netstring, so no path/content boundary is ambiguous and no two distinct
  change sets can frame to the same bytes.

  The changes are SORTED by the full `{path, operation, content}` triple
  before framing. Sorting is what makes the digest a function of the change
  SET rather than of the collector's iteration order, which nothing in the
  port contract guarantees; sorting by the full triple (not by `path` alone)
  keeps the order total even if two entries ever share a path, so the digest
  stays independent of input order in that case too.

  ## Per-stage discipline

  **Facts first, then CAS.** A stage writes its facts and only then runs
  `Store.transition/4`. A crash between the two retries into the same stage:
  the facts write is keyed by `run_id` and idempotent, then the CAS runs. The
  reverse order would leave a run claiming a state whose facts are absent —
  which is precisely the durable evidence a resumed run reads.

  **Fresh reads.** Every stage re-reads the run with `Store.read_run/1` rather
  than trusting a caller's struct: `state_version` must be current or the CAS
  asserts nothing.

  **No implicit catch-up.** A stage invoked in the wrong state returns
  `{:error, {:unexpected_status, status}}` and does nothing. It does not run
  the earlier stages to "get there".

  ## The write ordering that closes P3's provenance gap

  `deterministic_head_ref` is written to `git_workflow_facts` BEFORE the first
  `:create_change_request` invocation — not after it, not in the same step.
  `apps/ezagent_plugin_github/lib/.../github_adapter.ex` records a KNOWN
  LIMITATION: when the deterministic ref exists but still points at base, the
  adapter cannot tell its own retry's ref from a foreign ref planted at the
  same name, because there is no commit yet whose provenance it could compare.
  It names the fix as "the workflow's own durable facts (design §5.3)
  recording which ref belongs to which run". A run that crashes between the
  fact write and the provider call retries into "the facts say this ref is
  mine" — the identity the adapter lacks. Written afterwards, the fact would
  be absent in exactly the window it exists for.

  The ref value is `DeterministicRef.derive/2` over the binding's
  `allowed_head_namespace` and the run id — the same function
  `PolicyDerivation` uses for the policy's `allowed_head_ref`. The runner does
  not merely assume the two agree: it compares them and fails closed if they
  do not, because a drift would otherwise surface as the action set rejecting
  the request at dispatch time, which reads like a policy bug rather than a
  derivation bug.

  ## Failure handling

  Every stage failure goes through `Blocker.from_error/1` then
  `Blocker.classify/1` (§7.2):

    * `:terminal_blocker` → the code is recorded on the run, then a CAS to
      `blocked`. Stop.
    * `:retryable` → the code is recorded, the state is left ALONE, and the
      caller gets `{:retry, presentation}`. Bounded retry is the caller's
      policy; this module never sleeps and never loops.

  The code is recorded BEFORE the CAS for the same reason facts are: a crash
  between them retries the stage, whereas a run marked `blocked` with no code
  is a dead end an operator cannot triage.

  `failed` and `cancelled` are the only terminal states and the runner NEVER
  sets them — an operator does. `blocked → blocked` is a legal edge, and
  `fail/4` CASes from whatever status the run currently holds, so re-recording
  is not an illegal transition; `advance/2` itself will not re-enter a
  `blocked` run, since `blocked` maps to no stage.

  Presentation is `Blocker.present/4` — code, stage, retryable, attempt, safe
  metadata, and nothing else. No dispatch term, provider body, token or path
  reaches a persisted column or a return value.
  """

  alias Ezagent.DomainGit.ChangeRequest
  alias Ezagent.DomainGit.CommitSha
  alias Ezagent.DomainGit.CreateChangeRequest
  alias Ezagent.DomainGit.FileChange
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.Blocker
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @digest_version "gitworkflow.change_digest.v1"

  # The stage each non-terminal status owes. A status absent from this map
  # owes nothing — including `pr_open` (P4d's observation tick) and every
  # control state.
  @stages %{
    "authorized" => :provision_workspace,
    "workspace_ready" => :collect_workspace_changes,
    "changes_ready" => :create_change_request
  }

  @type presentation :: %{
          code: Blocker.code(),
          stage: atom(),
          retryable: boolean(),
          attempt: non_neg_integer(),
          metadata: map()
        }

  @type result ::
          {:ok, WorkflowRun.t()}
          | {:blocked, presentation()}
          | {:retry, presentation()}
          | {:error, term()}

  @doc """
  Performs the ONE stage the run's current status owes, then returns.

  Returns:

    * `{:ok, run}` — the stage succeeded and the run is at its next status;
    * `{:blocked, presentation}` — a terminal blocker; the run is at `blocked`
      and the code is persisted;
    * `{:retry, presentation}` — a retryable failure; the status is unchanged
      and the code is persisted. Retrying is the caller's decision;
    * `{:error, {:unexpected_status, status}}` — the run owes no stage;
    * `{:error, reason}` — the run does not exist, or the CAS lost a race.

  `:attempt` (default `0`) is carried into the presentation only. This module
  neither counts attempts nor bounds them (§7.2 leaves the bound to the
  caller), but a caller that IS retrying should label which attempt this is,
  or the presentation misreports it as the first.
  """
  @spec advance(String.t(), keyword()) :: result()
  def advance(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    attempt = Keyword.get(opts, :attempt, 0)

    case Store.read_run(run_id) do
      {:ok, run} -> advance_run(run, attempt)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The deterministic digest of a collected change set — see the moduledoc for
  the exact hash input and why the set is sorted.

  Public because P4d/P4e and any future re-collection must be able to compute
  the SAME value without re-deriving the framing from this module's source.
  """
  @spec change_digest([FileChange.t()]) :: String.t()
  def change_digest(changes) when is_list(changes) do
    framed_changes =
      changes
      |> Enum.map(fn %FileChange{path: path, operation: operation, content: content} ->
        {path, Atom.to_string(operation), content}
      end)
      |> Enum.sort()
      |> Enum.map(fn {path, operation, content} ->
        [framed(path), framed(operation), framed(content)]
      end)

    digest = :crypto.hash(:sha256, [framed(@digest_version) | framed_changes])
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  # A netstring: length-prefixed bytes. Concatenating raw fields would let
  # `{"ab", "c"}` and `{"a", "bc"}` hash identically.
  defp framed(value) when is_binary(value),
    do: [Integer.to_string(byte_size(value)), ":", value]

  # ---------------------------------------------------------------------------
  # Stage selection
  # ---------------------------------------------------------------------------

  defp advance_run(%WorkflowRun{status: status} = run, attempt) do
    case Map.fetch(@stages, status) do
      {:ok, stage} -> authorized_stage(run, stage, attempt)
      :error -> {:error, {:unexpected_status, status}}
    end
  end

  # `ExecutionSeam.authorize/2` is re-asked on every stage rather than cached
  # from the `accepted → authorized` transition. It is pure and side-effect
  # free by contract (§3.1), and re-deriving means a binding that was disabled
  # or re-generated between stages denies the NEXT stage instead of the run
  # continuing on a stale authorization.
  defp authorized_stage(%WorkflowRun{binding_id: binding_id} = run, stage, attempt) do
    with {:ok, binding} <- read_binding(binding_id),
         {:ok, task} <- ExecutionSeam.authorize(run, binding) do
      run_stage(stage, run, binding, task, attempt)
    else
      {:error, reason} -> fail(run, stage, attempt, reason)
    end
  end

  # A run whose binding row is gone cannot be authorized and cannot be repaired
  # by retrying. It is recorded as a blocker on the run rather than returned as
  # an opaque error, so an operator sees it where they look for it. The store's
  # reason is dropped — it names a row, and the run already names the binding.
  defp read_binding(binding_id) do
    case Store.read_binding(binding_id) do
      {:ok, binding} -> {:ok, binding}
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: authorized → workspace_ready
  # ---------------------------------------------------------------------------

  defp run_stage(:provision_workspace, run, _binding, task, attempt) do
    case ExecutionSeam.invoke(task, :provision_workspace, task_args(run)) do
      {:ok, result} -> persist_provision(run, result, attempt)
      {:error, reason} -> fail(run, :provision_workspace, attempt, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: workspace_ready → changes_ready
  # ---------------------------------------------------------------------------

  defp run_stage(:collect_workspace_changes, %WorkflowRun{id: run_id} = run, _binding, task, att) do
    with {:ok, changes} <- collect(task, run),
         {:ok, _facts} <- update_facts(run_id, %{change_digest: change_digest(changes)}) do
      transition(run, "changes_ready")
    else
      {:error, reason} -> fail(run, :collect_workspace_changes, att, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: changes_ready → pr_open
  # ---------------------------------------------------------------------------

  defp run_stage(:create_change_request, %WorkflowRun{id: run_id} = run, binding, task, attempt) do
    with {:ok, changes} <- collect(task, run),
         {:ok, facts} <- read_facts(run_id),
         :ok <- verify_digest(facts, changes),
         {:ok, head_ref} <- head_ref(run, binding, task),
         {:ok, request} <- create_request(run, facts, head_ref),
         # THE ordering (see moduledoc): the fact that says "this ref is mine"
         # is durable before anything can create the ref.
         {:ok, _facts} <- update_facts(run_id, %{deterministic_head_ref: head_ref}),
         {:ok, change_request} <- invoke_create(task, changes, request),
         {:ok, _facts} <- persist_change_request(run_id, change_request) do
      transition(run, "pr_open")
    else
      {:error, reason} -> fail(run, :create_change_request, attempt, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Seam calls
  # ---------------------------------------------------------------------------

  # Exactly the key set `@allowed_keys` declares for these two actions in the
  # Git task-access action set — an extra key is refused before the handler.
  defp task_args(%WorkflowRun{source_task_uri: task_uri, binding_generation: generation}),
    do: %{task_uri: task_uri, generation: generation}

  defp collect(task, run) do
    case ExecutionSeam.invoke(task, :collect_workspace_changes, task_args(run)) do
      # An empty list is design §7.1's `:no_changes_collected`, not an empty
      # success. The shipped collector already answers with that code, but a
      # `{:ok, []}` from any other implementation must not reach
      # `FileChange.validate_many/1`, which would report a normal outcome as
      # `:invalid_file_change`.
      {:ok, []} -> {:error, :no_changes_collected}
      {:ok, [%FileChange{} | _] = changes} -> {:ok, changes}
      {:ok, _other} -> {:error, :internal_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_create(
         %AuthorizedTask{policy: %GitTaskAccess{repository: repository}} = task,
         changes,
         request
       ) do
    case ExecutionSeam.invoke(task, :create_change_request, %{
           changes: changes,
           repository: repository,
           request: request
         }) do
      {:ok, %ChangeRequest{} = change_request} -> {:ok, change_request}
      {:ok, _other} -> {:error, :internal_error}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Facts
  # ---------------------------------------------------------------------------

  defp persist_provision(
         run,
         %{status: :ready, provision_id: provision_id, resolved_base_commit: base},
         attempt
       ) do
    with {:ok, %CommitSha{value: normalized}} <- commit_sha(base),
         {:ok, _facts} <-
           establish_facts(run, %{
             workspace_provision_id: provision_id,
             expected_base_sha: normalized
           }) do
      transition(run, "workspace_ready")
    else
      {:error, reason} -> fail(run, :provision_workspace, attempt, reason)
    end
  end

  # The ready result also carries `start_token`. This clause binds NOTHING out
  # of the map and reports no part of it: a result that does not match the
  # success shape is a port-contract violation, and echoing it is how a token
  # reaches a log line.
  defp persist_provision(run, _result, attempt),
    do: fail(run, :provision_workspace, attempt, :internal_error)

  defp persist_change_request(run_id, %ChangeRequest{
         external_id: external_id,
         url: url,
         head_ref: head_ref,
         head_sha: head_sha,
         base_ref: base_ref,
         state: state
       }) do
    update_facts(run_id, %{
      change_request_id: external_id,
      change_request_url: URI.to_string(url),
      change_request_state: Atom.to_string(state),
      change_request_head_ref: head_ref,
      change_request_base_ref: base_ref,
      head_sha: head_sha
    })
  end

  # `upsert_facts/1` establishes the row; it is a full-row replace, which is
  # safe HERE and only here — this is the first stage, so there is no earlier
  # stage's fact for it to erase. Every later stage writes through
  # `update_facts/2` instead.
  defp establish_facts(%WorkflowRun{id: run_id, workspace_uri: workspace_uri}, attrs) do
    attrs
    |> Map.merge(%{id: facts_id(run_id), run_id: run_id, workspace_uri: workspace_uri})
    |> WorkflowFacts.new()
    |> case do
      {:ok, facts} -> Store.upsert_facts(facts)
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  # Deterministic, so a retried first stage reuses the row it already created
  # instead of racing a second identity onto the same `run_id`.
  defp facts_id("run_" <> digest), do: "fact_" <> digest

  defp update_facts(run_id, attrs) do
    case Store.update_facts(run_id, attrs) do
      {:ok, facts} -> {:ok, facts}
      # `:not_found` / `:unknown_fields` / `{:invalid_field, _}` are all runner
      # defects, not provider outcomes: `Blocker.from_error/1` lands them on
      # `:internal_error`, which is terminal, which is where a defect belongs.
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  defp read_facts(run_id) do
    case Store.read_facts(run_id) do
      {:ok, facts} -> {:ok, facts}
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  defp verify_digest(%WorkflowFacts{change_digest: recorded}, changes) do
    if change_digest(changes) == recorded,
      do: :ok,
      else: {:error, :change_digest_mismatch}
  end

  # ---------------------------------------------------------------------------
  # Request construction
  # ---------------------------------------------------------------------------

  # Derived independently AND compared, rather than read straight off the
  # policy: the fact must record the ref this run owns, and the request's
  # `head_ref` must be the one the policy allows. If those two could ever
  # differ the action set would refuse the request at dispatch time and the
  # failure would read like a policy bug — so a disagreement stops here, named
  # for what it is.
  defp head_ref(
         %WorkflowRun{id: run_id},
         %TaskBinding{allowed_head_namespace: namespace},
         %AuthorizedTask{policy: %GitTaskAccess{allowed_head_ref: allowed_head_ref}}
       ) do
    if DeterministicRef.derive(namespace, run_id) == allowed_head_ref,
      do: {:ok, allowed_head_ref},
      else: {:error, :internal_error}
  end

  # `commit_date` is `run.inserted_at` — the moment the run was durably
  # accepted (design §6.1, corrected 2026-07-27). It is written once and never
  # touched again (`upsert_facts`' update clause excludes `inserted_at`), so a
  # retry stamps the SAME date and the provider-side commit reproduces the same
  # sha. Reading the wall clock here would break exactly that.
  #
  # Title and body are deterministic functions of immutable run columns. They
  # are NOT identity — §6.2 forbids reconciling a change request by title or
  # body — but a value that varied per attempt would still make two retries
  # produce visibly different requests for no reason.
  defp create_request(
         %WorkflowRun{
           id: run_id,
           external_task_id: external_task_id,
           binding_generation: generation,
           inserted_at: commit_date
         },
         %WorkflowFacts{expected_base_sha: expected_base_sha},
         head_ref
       ) do
    with {:ok, base} <- commit_sha(expected_base_sha),
         {:ok, request} <-
           CreateChangeRequest.new(%{
             title: "ezagent: " <> external_task_id,
             body: "Automated change request.\n\nrun: #{run_id}\ngeneration: #{generation}\n",
             head_ref: head_ref,
             expected_base_sha: base,
             commit_date: commit_date
           }) do
      {:ok, request}
    else
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  # The provisioner's `resolved_base_commit` is a plain string. Normalizing it
  # through the domain value type on the way IN means a non-SHA never reaches
  # the facts row, so the create stage's rebuild cannot fail on data the
  # provision stage already accepted.
  defp commit_sha(value) do
    case CommitSha.new(%{value: value}) do
      {:ok, commit_sha} -> {:ok, commit_sha}
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Transitions and failure
  # ---------------------------------------------------------------------------

  defp transition(%WorkflowRun{id: id, state_version: version, status: status}, next_status),
    do: Store.transition(id, version, status, next_status)

  defp fail(
         %WorkflowRun{id: id, status: status, state_version: version},
         stage,
         attempt,
         reason
       ) do
    code = Blocker.from_error(reason)
    presentation = Blocker.present(code, stage, attempt, %{})

    # Recorded before the CAS: a crash in between retries the stage, whereas a
    # run sitting at `blocked` with no code cannot be triaged.
    _ = Store.record_error_code(id, Atom.to_string(code))

    case Blocker.classify(code) do
      :terminal_blocker -> block(id, version, status, presentation)
      :retryable -> {:retry, presentation}
    end
  end

  defp block(id, version, status, presentation) do
    case Store.transition(id, version, status, "blocked") do
      {:ok, _run} -> {:blocked, presentation}
      {:error, reason} -> {:error, {:block_failed, reason}}
    end
  end
end
