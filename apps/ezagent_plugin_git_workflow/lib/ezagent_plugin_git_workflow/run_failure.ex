defmodule EzagentPluginGitWorkflow.RunFailure do
  @moduledoc """
  Design §7.2's failure protocol, in ONE place: normalize the reason to a stable
  code, record the code on the run, then either CAS to `blocked` or hand the
  caller a retry.

  Extracted from `EzagentPluginGitWorkflow.StageRunner` (Slice P4c) when Slice
  P4d's observation tick turned out to need the identical protocol. Two copies
  of it would be two places to get the ORDER wrong, and the order is the part
  that matters:

  > **The code is recorded BEFORE the CAS.** A crash between the two retries the
  > stage, which is recoverable. A run sitting at `blocked` with no
  > `last_error_code` is a dead end an operator cannot triage.

  `retryable` in the presentation is derived by `Blocker.present/4` from
  `Blocker.classify/1` and can never be passed in, so a caller cannot report a
  failure as retryable that policy says is terminal, or the reverse.
  """

  alias EzagentPluginGitWorkflow.Blocker
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  @type presentation :: %{
          code: Blocker.code(),
          stage: atom(),
          retryable: boolean(),
          attempt: non_neg_integer(),
          metadata: map()
        }

  @type t ::
          {:blocked, presentation()}
          | {:retry, presentation()}
          | {:error, term()}

  @doc """
  Records `reason`'s stable code on `run` and lets `Blocker.classify/1` decide
  what happens to the run's state.

    * `:terminal_blocker` → CAS to `blocked`, `{:blocked, presentation}`;
    * `:retryable` → the status is left ALONE, `{:retry, presentation}`.
      Whether and when to retry is the caller's policy; nothing here sleeps,
      loops or counts attempts.

  `attempt` is carried into the presentation only. A caller that IS retrying
  should label which attempt this is, or the presentation misreports it as the
  first.
  """
  @spec fail(WorkflowRun.t(), atom(), non_neg_integer(), term()) :: t()
  def fail(%WorkflowRun{} = run, stage, attempt, reason) do
    code = Blocker.from_error(reason)

    case Blocker.classify(code) do
      :terminal_blocker -> block(run, stage, attempt, code)
      :retryable -> {:retry, record(run, stage, attempt, code)}
    end
  end

  @doc """
  Records `code` and CASes the run to `blocked`, WITHOUT asking
  `Blocker.classify/1`.

  Use this only where the decision to stop belongs to the CALLER rather than to
  the failure. V1 has exactly one such case: design §7.2's last bullet, "达到
  deadline:明确 `blocked: observation_incomplete`". The observation tick's
  caller owns the cadence and the budget, so when the budget is spent the run
  stops — whether or not the condition it was waiting on is one that could still
  clear on its own.

  Everything a port or adapter reports must go through `fail/4` instead, so the
  §7.2 classification stays the single authority on which failures stop a run.
  """
  @spec block(WorkflowRun.t(), atom(), non_neg_integer(), Blocker.code()) :: t()
  def block(%WorkflowRun{id: id, status: status, state_version: version} = run, stage, attempt, code) do
    presentation = record(run, stage, attempt, code)

    case Store.transition(id, version, status, "blocked") do
      {:ok, _run} -> {:blocked, presentation}
      {:error, reason} -> {:error, {:block_failed, reason}}
    end
  end

  defp record(%WorkflowRun{id: id}, stage, attempt, code) do
    _ = Store.record_error_code(id, Atom.to_string(code))
    Blocker.present(code, stage, attempt, %{})
  end
end
