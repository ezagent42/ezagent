defmodule EzagentPluginGitWorkflow.CrashingSeam do
  @moduledoc """
  The REAL `ExecutionSeam.CapBacked` backend with one added behaviour: after a
  nominated action has completed and its answer is in hand, this process dies.

  That is the only way to reach design §6.2's fifth crash window —
  "observation HTTP 成功后、snapshot 落库前" — from outside the runner. The
  window is a gap between two statements in `Observation.observe/2`:

      {:ok, reviews} <- list_reviews(task, change_request_id),
      {:ok, _persisted} <- persist(run_id, facts, fresh, checks, reviews)

  Nothing a stub provider can do reaches it: a provider that FAILS the read
  never produces the answer the window is defined by, and the tick then takes
  the ordinary failure path instead. So the interposition has to be here, on
  the far side of the seam call, after the answer exists.

  It is a WRAPPER, not a fake. Every call is forwarded to `CapBacked` and runs
  the whole real path — cap minting, dispatch, the Git task-access action set,
  the adapter, the provider. `armed_result/0` hands the test the answer that
  really came back, so "the response was received" is asserted rather than
  assumed.

  The arming is per-process (`Process.put/2`), like
  `ExecutionSeamTestDelegate`'s own backend selection, so it cannot leak
  between tests.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked

  defmodule Crash do
    @moduledoc "Raised in place of the process that would have died."
    defexception message: "the world ended between the provider's answer and the DB write"
  end

  @armed {__MODULE__, :armed}
  @result {__MODULE__, :result}

  @doc "Arms the crash for the NEXT successful `action` in this process."
  @spec crash_after(atom()) :: :ok
  def crash_after(action) when is_atom(action) do
    Process.put(@armed, action)
    Process.delete(@result)
    :ok
  end

  @doc "The provider answer that was in hand at the moment of the crash."
  @spec armed_result() :: term()
  def armed_result, do: Process.get(@result)

  @impl true
  def authorize(run, binding), do: CapBacked.authorize(run, binding)

  @impl true
  def invoke(authorized_task, action, typed_args) do
    result = CapBacked.invoke(authorized_task, action, typed_args)

    # The check runs AFTER the forwarded call, deliberately: a crash armed
    # before it would prove nothing about a window that only exists once the
    # answer has arrived.
    if Process.get(@armed) == action and match?({:ok, _}, result) do
      Process.delete(@armed)
      Process.put(@result, result)
      raise Crash
    end

    result
  end
end
