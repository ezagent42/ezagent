defmodule Ezagent.Kind.UnsanctionedMailboxError do
  @moduledoc """
  V5 use-side H3 (the SEAL) — raised by `Ezagent.Kind.Server` in `:dev`/`:test`
  when a NON-sanctioned term reaches the Kind mailbox's `handle_info/2` door.

  After the seal, a Kind's mailbox accepts ONLY:

    * `%EzagentActor.Signal{}` envelopes (the framework transport —
      `EzagentActor.Signal.signal/2`, `broadcast/2`, `monitor/1`,
      `send_after/2`), and
    * VM-generated `{:EXIT, pid, reason}` tuples (the Kind traps exits; a
      linked-resource death cannot be envelope-wrapped by an application
      producer, so it keeps a dedicated framework clause).

  Everything else is a MISSED PRODUCER — a raw `send/2`, `Process.send_after/3`,
  `Process.monitor/1`-DOWN, task reply, or raw PubSub payload that B2/H1/H2 did
  not migrate onto the Signal transport. Per Allen (0727) this is FAIL-LOUD, not
  silent-drop: in `:dev`/`:test` the Kind RAISES this error so the offending
  producer's test screams; in `:prod` the server emits
  `[:ezagent, :kind, :unsanctioned_mailbox]` telemetry + a `Logger.error` and
  drops the term (loud, never silent, never forwarded to behaviors, never
  persisted).

  If you see this raise: migrate the producer to `EzagentActor.Signal` (same
  pattern as B2-core / H1 / H2). Do NOT silence the raise.
  """
  defexception [:door, :uri, :kind, :offending_term]

  @impl true
  def message(%{door: door, uri: uri, kind: kind, offending_term: term}) do
    "unsanctioned #{door} ingress on SEALED Kind mailbox " <>
      "uri=#{inspect(uri)} kind=#{inspect(kind)} " <>
      "term=#{inspect(term, limit: 50, printable_limit: 4096)} — " <>
      "the mailbox accepts only %EzagentActor.Signal{} envelopes and " <>
      "VM-generated {:EXIT, pid, reason}. This raise is the migration " <>
      "completeness proof: migrate the missed producer to EzagentActor.Signal, " <>
      "do not silence the raise."
  end
end
