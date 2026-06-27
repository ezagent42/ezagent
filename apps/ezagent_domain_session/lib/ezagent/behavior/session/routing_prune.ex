defmodule Ezagent.Behavior.Session.RoutingPrune do
  @moduledoc """
  Session-scoped routing-row prune for a removed participant.

  Extracted from `Ezagent.Orchestrator.Tools` (F7 PR-A) so BOTH the
  orchestrator's `remove_member` MCP path AND the new isomorphic
  `Behavior.Session.remove_participant` primitive share ONE prune
  implementation (no fork — the lead's cross-op-consistency requirement).

  The prune is SCOPED to rules created BY this session (`created_by ==
  session_uri`, the B1/PR-7 stamp) so a same-named URI referenced by ANOTHER
  session's rule-set is never touched; and a prune/repoint FAILURE FAILS the
  caller (`{:error, _}`) atomically rather than being swallowed into
  `deleted_rules: 0` while removal silently continues (codex B2 fix).

  - rules left with ZERO receivers after dropping the member are
    force-DELETED (routing LOST, also `Logger.warning`ed) → `deleted_rules`.
  - rules that merely drop the member but keep other receivers are
    repointed → `repointed_rules`.
  """

  require Logger

  @type counts :: %{deleted_rules: non_neg_integer(), repointed_rules: non_neg_integer()}

  @doc """
  Prune routing rows naming `member_uri`, scoped to rules `created_by`
  `session_uri`. Returns `{:ok, %{deleted_rules:, repointed_rules:}}` or
  `{:error, reason}` (failing atomically).
  """
  @spec prune_routing_rules_for(URI.t(), URI.t()) :: {:ok, counts()} | {:error, term()}
  def prune_routing_rules_for(%URI{} = session_uri, %URI{} = member_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    member_str = URI.to_string(member_uri)
    session_str = URI.to_string(session_uri)

    txn =
      EzagentCore.Repo.transaction(fn ->
        rules = Ezagent.Routing.RuleStore.list(table)

        rules
        |> Enum.filter(fn rule ->
          rule.created_by == session_str and member_str in (rule.receivers || [])
        end)
        |> Enum.reduce_while({[], 0}, fn rule, {deleted_meta, repointed} ->
          remaining =
            (rule.receivers || [])
            |> Enum.reject(fn r -> r == member_str end)
            |> Enum.uniq()

          {result, acc} =
            if remaining == [] do
              {Ezagent.Routing.RuleStore.delete(rule.id, force: true),
               {[{rule.id, Map.get(rule, :matcher_data, :unknown)} | deleted_meta], repointed}}
            else
              {Ezagent.Routing.RuleStore.update_receivers(rule.id, remaining, rule.enabled),
               {deleted_meta, repointed + 1}}
            end

          case result do
            :ok -> {:cont, acc}
            {:error, reason} -> EzagentCore.Repo.rollback({:prune_failed, reason})
          end
        end)
      end)

    case txn do
      {:ok, {deleted_meta, repointed}} ->
        case reload_registry(table) do
          :ok ->
            Enum.each(deleted_meta, fn {id, matcher} ->
              Logger.warning(
                "remove_participant routing GC: force-deleted routing rule " <>
                  "id=#{inspect(id)} matcher=#{inspect(matcher)} " <>
                  "because removing member #{member_str} left it with ZERO receivers. " <>
                  "Routing to this rule is LOST — re-adding the member does NOT restore it."
              )
            end)

            {:ok, %{deleted_rules: length(deleted_meta), repointed_rules: repointed}}

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:prune_failed, e}}
  catch
    kind, reason -> {:error, {:prune_failed, {kind, reason}}}
  end

  @doc """
  Force-delete ALL routing rows `created_by` this session (F7 PR-B, SPEC §4.1
  step 4 — the delete-session cascade prune). Unlike `prune_routing_rules_for/2`
  (which repoints rules that keep other receivers), the whole session is going
  away, so every rule it created is dropped outright. Mirrors the
  `SessionCreator.Rollback.delete_session_rule_rows/1` primitive. Best-effort:
  reloads the registry and returns `:ok`.
  """
  @spec prune_all_for_session(URI.t()) :: :ok | {:error, term()}
  def prune_all_for_session(%URI{} = session_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    session_str = URI.to_string(session_uri)

    table
    |> Ezagent.Routing.RuleStore.list()
    |> Enum.filter(fn row -> row.created_by == session_str end)
    |> Enum.each(fn row -> Ezagent.Routing.RuleStore.delete(row.id, force: true) end)

    reload_registry(table)
  end

  @doc """
  Reload the routing rule registry from the rule store after a mutation.
  """
  @spec reload_registry(module()) :: :ok | {:error, term()}
  def reload_registry(table) do
    Ezagent.Routing.RuleStore.load_into_registry(table)
    :ok
  rescue
    e -> {:error, {:registry_reload_failed, e}}
  catch
    _, reason -> {:error, {:registry_reload_failed, reason}}
  end
end
