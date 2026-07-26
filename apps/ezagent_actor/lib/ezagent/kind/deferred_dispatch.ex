defmodule Ezagent.Kind.DeferredDispatch do
  @moduledoc """
  Post-commit (deferred) re-entrant dispatch for `Ezagent.Kind.Server` (P2.5c).

  A Behavior may emit a `{:dispatch_after_commit, %Cmd{}}` effect: a re-entrant
  dispatch that must fire ONLY after the EMITTING Kind's own slice durably
  committed. `Runtime.Effects.execute_buckets` collects these into a separate
  bucket and threads them out of `handle_dispatch` as the `deferred` list (already
  ref-substituted + enriched with `caller=self_uri`, so they dispatch with the
  emitting Kind's authority, NOT `:system`). `Kind.Server` then hands that list to
  this module at the SAME gate as `SliceChange.emit` — after `commit_and_notify`
  returns `:ok`/`:not_durable`, never on `{:error, _}`. This closes the rev4
  ordering bug: a settlement / customer-delivery must not outlive a failed
  parent-turn commit.

  ## Why enqueue instead of run inline (codex P2.5c impl HIGH)

  `enqueue/1` sends `{:ezagent_run_deferred, cmds}` to the calling server's own
  mailbox, so the actual `Router.dispatch` runs on a LATER `handle_info` turn —
  NOT inline in the `handle_call`/`handle_cast` callback that just committed. A
  crash in the window between the parent commit and that message is exactly what
  `Behavior.Turn.activated/2` (Task 7) recovers, so an enqueued-but-unrun deferred
  is not a durable loss.

  ## Why force fire-and-forget (codex P2.5c impl HIGH)

  A post-commit deferred dispatch is inherently fire-and-forget — the original
  action already replied to its caller, so a deferred Cmd can never return a value
  to anyone. `run/1` pins `mode: :cast` + `reply: :ignore` so `Router.derive_mode/1`
  resolves to `:cast` regardless of what the emitting Behavior left on the Cmd's
  ctx. A self-targeted deferred Cmd can therefore NEVER synchronously
  `GenServer.call` the still-running server and deadlock/drop.

  ## Failure handling

  The parent commit already succeeded, so a failure here is OBSERVATIONAL: `run/1`
  logs BOTH a `{:error, reason}` Router return AND a raised exception at `:error`
  (codex P2.5c MEDIUM: never silently drop a post-commit dispatch — the
  orphan-in-the-other-direction). All cmds run regardless of an individual failure.
  Durable retry is `Turn.activated/2` recovery + P3's outbox replay.
  """

  require Logger

  @doc """
  Enqueue the deferred Cmds to the CALLING process's mailbox (the `Kind.Server`),
  to be run on a later `handle_info({:ezagent_run_deferred, cmds}, state)` turn.

  Must be called synchronously from inside the server process so `self()` is the
  server. A no-op for an empty list.
  """
  @spec enqueue([Ezagent.Cmd.t()]) :: :ok
  def enqueue([]), do: :ok

  def enqueue(cmds) when is_list(cmds) do
    # V5 use-side B2 — deliver through the sanctioned envelope. No
    # `self_uri` is in scope here (`enqueue/1` only carries the Cmds), so
    # this is the bare-self raw-wrap form: same mailbox ordering as the
    # previous raw `send/2`, arriving as `%EzagentActor.Signal{}` which
    # `Kind.Server.handle_info/2` unwraps back to `{:ezagent_run_deferred, cmds}`.
    send(self(), %EzagentActor.Signal{
      kind: :signal,
      payload: {:ezagent_run_deferred, cmds}
    })

    :ok
  end

  @doc """
  Run the deferred post-commit Cmds via `Router.dispatch`, each forced to
  fire-and-forget. Logs (never raises) on per-Cmd failure. Returns `:ok`.
  """
  @spec run([Ezagent.Cmd.t()]) :: :ok
  def run([]), do: :ok

  def run(cmds) when is_list(cmds) do
    Enum.each(cmds, fn %Ezagent.Cmd{} = cmd ->
      cmd = force_fire_and_forget(cmd)

      try do
        case dispatch_as_reviewed_operator(cmd) do
          :ok ->
            :ok

          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Kind.DeferredDispatch.run: post-commit dispatch FAILED " <>
                "target=#{inspect(cmd.target)} action=#{inspect(cmd.action)} " <>
                "reason=#{inspect(reason)} — parent slice committed but this side " <>
                "effect did not run"
            )
        end
      catch
        kind, reason ->
          Logger.error(
            "Kind.DeferredDispatch.run: post-commit dispatch RAISED " <>
              "target=#{inspect(cmd.target)} action=#{inspect(cmd.action)} " <>
              "#{inspect({kind, reason})}"
          )
      end
    end)
  end

  defp force_fire_and_forget(%Ezagent.Cmd{ctx: ctx} = cmd) do
    %{cmd | ctx: ctx |> Map.put(:mode, :cast) |> Map.put(:reply, :ignore)}
  end

  # Deferred commands are emitted only by reviewed Behavior code after the
  # parent mutation commits. Preserve that framework provenance explicitly so
  # canonical-admin commands can obtain an exact, receiver-bound artifact from
  # the target Kind's K.grant path. Non-admin presenters are unchanged because
  # Invocation's scope check is presenter-bound and canonical-admin-only.
  defp dispatch_as_reviewed_operator(
         %Ezagent.Cmd{ctx: %{authenticated_principal: %URI{} = holder}} = cmd
       ) do
    Ezagent.Invocation.with_admin_operator(holder, fn -> Ezagent.Router.dispatch(cmd) end)
  end

  defp dispatch_as_reviewed_operator(%Ezagent.Cmd{} = cmd), do: Ezagent.Router.dispatch(cmd)
end
