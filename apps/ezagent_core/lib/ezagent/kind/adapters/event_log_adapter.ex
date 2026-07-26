defmodule Ezagent.Kind.Adapters.EventLogAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.EventLogPort` (§3.4) — wraps
  `Ezagent.EventLog.append/4`.

  `Ezagent.EventLog.append/4` REQUIRES `ctx.workspace_uri` (the
  `invocations.workspace_uri` column is NOT NULL) while the actor side of
  the port never supplies it: this adapter DERIVES the workspace scope from
  the event's target via `Ezagent.Persistence.workspace_uri_for/1` — the
  same policy the PersistencePort fronts for snapshot rows — and injects
  it into the ctx. A target whose workspace cannot be derived returns
  `{:error, :no_workspace}` under the same best-effort rule (callers log
  and continue; audit never fails dispatch). STAYS in core when the
  framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.EventLogPort

  @impl true
  def append(uri, event, payload, ctx) when is_map(payload) and is_map(ctx) do
    case Ezagent.Persistence.workspace_uri_for(uri) do
      {:ok, workspace_uri} ->
        ctx =
          ctx
          |> Map.put(:workspace_uri, workspace_uri)
          |> Map.update(:caller, nil, &normalize_caller/1)

        Ezagent.EventLog.append(uri, event, payload, ctx)

      {:error, :no_workspace} = err ->
        err
    end
  end

  # `Ezagent.EventLog.append/4`'s `:caller` accepts only nil / URI / binary
  # — translate anything else (e.g. the `:vm_internal` atom) to nil so the
  # audit row records "no entity caller" instead of raising.
  defp normalize_caller(nil), do: nil
  defp normalize_caller(%URI{} = u), do: u
  defp normalize_caller(s) when is_binary(s), do: s
  defp normalize_caller(_), do: nil
end
