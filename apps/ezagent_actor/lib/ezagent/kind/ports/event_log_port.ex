defmodule Ezagent.Kind.Ports.EventLogPort do
  @moduledoc """
  §3.4 EventLogPort — the actor framework's audit/event sink, resolved via
  `Application.fetch_env!(:ezagent_actor, :event_log)`.

  ONE 4-arg contract. The actor side passes only `{uri, event, payload}` +
  trace/caller ctx and NEVER supplies `:workspace_uri` — the core adapter
  (`Ezagent.Kind.Adapters.EventLogAdapter`) DERIVES the workspace scope
  from the event's target via the core persistence/workspace policy
  (`Ezagent.Persistence.workspace_uri_for/1`) and injects it. Owner (core
  spine): `Ezagent.EventLog`. Moves with the framework to
  `apps/ezagent_actor`.
  """

  @doc """
  Append an event for `uri`. `ctx` carries `:caller` (nil / URI / binary)
  and `:trace_id` — never `:workspace_uri`. `{:ok, event_id}` on success;
  `{:error, reason}` (e.g. `:no_workspace` when the target's workspace
  cannot be derived) otherwise — callers treat every append as best-effort
  (audit is observational; it never fails dispatch).
  """
  @callback append(uri :: term(), event :: term(), payload :: map(), ctx :: map()) ::
              {:ok, term()} | {:error, term()}
end
