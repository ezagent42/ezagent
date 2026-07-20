defmodule Ezagent.ActionSet.Session.ConfigActions do
  @moduledoc false
  #
  # Working-copy + prompt-template management helpers extracted VERBATIM
  # from `Ezagent.ActionSet.Session` (PR-3R helper extraction). The
  # authorization predicates (`working_copy_write_authorized?/1`,
  # `orchestrator_cap_present?/1`) run in the same Session Kind process as
  # the `handle_set_working_copy/2` / `handle_set_prompt_templates/2`
  # callbacks; the `system_set_*` functions are `Ezagent.Router.dispatch`
  # round-trips identical to running in `Behavior.Session`.

  alias Ezagent.Cmd

  @doc """
  The empty/default `template_working_copy` shape (Phase 7 completion
  SPEC §1.3 / §1.6).

  Used by `create/1` for fresh Sessions and as the safe default
  when reading a pre-PR-2 Session snapshot whose `:chat` slice has no
  `template_working_copy` key.
  """
  @spec default_template_working_copy() :: map()
  def default_template_working_copy do
    %{
      # team-routing-unification §3.8 (PR-8) — `agent_slots` is REMOVED
      # (clean cutover, no shim). A "slot" was a member with extra facets
      # (§3.1); the orchestrator now builds a team via session MEMBERS +
      # RULE-SETS (see `Ezagent.Orchestrator.Tools.add_managed_member` +
      # `define_rule_set_rule`). Spawn-source state (`source_template_uri`)
      # lives on the member's `:members` meta, NOT a slot tuple.
      #
      # [{matcher_ast :: term(), [role_name :: String.t()]}]
      # rule-set routing rows (receivers are role_names / URIs, resolved on
      # instantiate). Kept for SessionTemplate snapshot compatibility.
      routing_rules: [],
      # Declared members that may be provisioned lazily by route-time role
      # resolution. Entries come from SessionTemplate.members and are not proof
      # that the member Kind is live or joined.
      member_declarations: [],
      # URI.t() | nil — the SessionTemplate this Session was
      # instantiated from (the Generator's `parent_template_uri`,
      # Task #110). Durable because Session is `{:snapshot, :on_change}`,
      # so it survives a phx restart. It is the canonical source the
      # lazy rebuild in
      # `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1` prefers
      # for the `:parent_template_uri` the `update_template` MCP tool
      # requires — NOT derivable from the session URI in the general case
      # (the `<owner>-<template>` path segment can be ambiguous). `nil`
      # for sessions that never went through the Generator (plain system
      # sessions) — those have no orchestrator.
      session_template_uri: nil,
      # URI.t() | nil — workspace newly-instantiated sessions land in
      default_workspace_uri: nil,
      # String.t() — human description of the team
      description: ""
    }
  end

  @doc """
  Read the durable `template_working_copy` field from a `:chat` slice,
  defaulting to `default_template_working_copy/0` when the key is
  absent (a pre-PR-2 Session snapshot — see `create/1`).
  """
  @spec template_working_copy(map()) :: map()
  def template_working_copy(chat_slice) when is_map(chat_slice) do
    Map.get(chat_slice, :template_working_copy, default_template_working_copy())
  end

  @doc """
  System-internal path to write the durable `template_working_copy`
  field (HIGH-2 hardening).

  `EzagentDomainInstanceMessage.SessionCreator.create_session/3` (the atomic single writer — the
  dead `Session.spawn_from_template/2` Generator was deleted in the
  2026-05-31 orchestrator-startup-atomicity pass) does the FIRST
  `template_working_copy` declaration and versioned binding writes before any orchestrator
  cap exists. It cannot hold the orchestrator's `{:within_session, _}`
  cap (the session is brand-new), so it uses this path: a
  `chat.set_working_copy` dispatch carrying `ctx[:system_internal] =
  true`. That marker is honored ONLY here and by
  `handle_set_working_copy/2`'s `working_copy_write_authorized?/1` — it
  is NOT settable from any user-facing dispatch (the MCP tool path
  supplies `caps`, never `system_internal`).

  Returns the dispatch result.
  """
  @spec system_set_working_copy(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_working_copy(%URI{} = session_uri, working_copy) when is_map(working_copy) do
    with {:ok, caps} <- session_self_cap(session_uri, :set_working_copy) do
      case Ezagent.Router.dispatch(%Cmd{
             target: session_uri,
             action: :set_working_copy,
             args: %{template_working_copy: working_copy},
             ctx: %{
               caller: session_uri,
               caps: caps,
               system_internal: true,
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
        {:ok, %{template_working_copy: _} = ok} -> {:ok, ok}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_working_copy_result, other}}
      end
    end
  end

  @doc """
  System-internal path to install the session-scoped named prompt-template map
  (team-routing-unification §3.4/§3.7, PR-7). Mirrors `system_set_legends/2`: a
  `chat.set_prompt_templates` dispatch under the `system://session-internal`
  principal. Used by tests and by the PR-7 SessionTemplate materialization path
  (which installs a template's `prompt_templates` at create_session time,
  before any orchestrator cap exists).

  Authorization is SESSION SELF-authority (#154): the dispatch runs as the
  session itself (`caller == self_uri`), recognized by
  `Legends.legends_write_authorized?` — NOT a ctx flag, NOT a system principal.
  """
  @spec system_set_prompt_templates(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def system_set_prompt_templates(%URI{} = session_uri, prompt_templates)
      when is_map(prompt_templates) do
    with {:ok, caps} <- session_self_cap(session_uri, :set_prompt_templates) do
      case Ezagent.Router.dispatch(%Cmd{
             target: session_uri,
             action: :set_prompt_templates,
             args: %{prompt_templates: prompt_templates},
             ctx: %{
               caller: session_uri,
               caps: caps,
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
        {:ok, %{prompt_templates: _} = ok} -> {:ok, ok}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_prompt_templates_result, other}}
      end
    end
  end

  @doc """
  Build the session's OWN inline cap (as a `MapSet`) for a self-slice config
  write (`:set_working_copy` / `:set_legends` / `:set_prompt_templates`).

  `granted_by` the session itself — a real entity exercising self-authority over
  its own `:chat` slice (the workspace-loader #832 pattern; #154 replaces the
  eliminated `system://session-internal` principal). `behavior: :any` avoids
  pinning the Session behavior module; `kind`/`action`/`instance` keep it
  least-privilege. Shared by `Legends.system_set_legends/2`.
  """
  @spec session_self_cap(URI.t(), atom()) :: {:ok, MapSet.t()} | {:error, term()}
  def session_self_cap(%URI{} = session_uri, action) when is_atom(action) do
    target = Ezagent.URI.with_action(session_uri, :session, action)
    admin = Ezagent.URI.user(:system, :admin)

    case Ezagent.Cap.issue_for_action({:admin, admin}, session_uri, target) do
      {:ok, cap} -> {:ok, MapSet.new([cap])}
      {:error, _reason} = error -> error
    end
  end
end
