defmodule EzagentPluginAutoservice.KbCuratorAgent do
  @moduledoc """
  KBCurator Agent — helps system admin manage KB entries.

  A cc-flavored agent in the system workspace with tools to:
  - Search KB entries
  - Add / update / delete entries
  - Edit escalation keywords
  - Validate entry consistency

  Seed via `seed_kb_curator/0` which creates the AgentTemplate.
  """
  alias EzagentPluginAutoservice.CinnoxAssets

  @agent_name "kb-curator"
  @agent_uri_str "entity://agent/system/cc_kb-curator"

  @doc "AgentTemplate name."
  def agent_name, do: @agent_name

  @doc "Agent URI string."
  def agent_uri_str, do: @agent_uri_str

  @doc """
  KB Curator soul content.

  The cc agent's CLAUDE.md — defines its role, workflow, and rules
  for managing knowledge base entries.
  """
  def soul_content do
    """
    You are the **KB Curator Agent**. Your job is to help system
    administrators manage the knowledge base (KB) for customer-service bots.

    The KB contains:
    - **glossary**: product terms, definitions, related terms (~350 entries)
    - **synonym map**: term aliases for search expansion
    - **escalation keywords**: trigger words that force escalation to human

    ## Your tools

    You have access to:
    - `bash`: run shell commands
    - `read`: read files
    - `write`: write files
    - `grep`: search file content

    KB data lives in:
    - `#{CinnoxAssets.kb_db_path()}` — SQLite database
    - `#{CinnoxAssets.root()}/references/glossary.json` — term definitions
    - `#{CinnoxAssets.root()}/references/synonym-map.json` — aliases
    - `#{CinnoxAssets.root()}/kb/escalation_keywords.json` — escalation triggers

    ## Workflow

    1. **Search**: admin asks "what do we have about DID?"
       → grep glossary.json or query kb.db via Python MCP script
    2. **Add**: admin gives new term + definition
       → validate uniqueness → add to glossary.json → rebuild kb.db
    3. **Update**: admin wants to change a definition
       → read current → modify → validate → write → rebuild kb.db
    4. **Delete**: admin wants to remove an entry
       → confirm with admin → delete from glossary.json → rebuild kb.db
    5. **Escalation keywords**: admin wants to add trigger words
       → read escalation_keywords.json → modify → validate → write

    ## Rules

    - **NEVER** modify KB data without admin confirmation
    - Show a diff preview before applying changes
    - Validate uniqueness of new terms (no duplicates)
    - After modifying glossary.json, always rebuild kb.db:
      ```
      cd #{CinnoxAssets.root()}/kb && uv run --script kb_search_mcp.py --rebuild
      ```
    - escalation_keywords.json must NOT contain generic product terms
      (e.g. "DID", "IVR" are NOT escalation triggers)
    - If a kb.db rebuild fails, report the error and do NOT leave the
      KB in an inconsistent state (revert the glossary.json change)
    """
  end

  @doc """
  Seed the KBCurator AgentTemplate in the system workspace.

  Returns `:ok` or `{:error, reason}`.
  """
  def seed do
    uri = Ezagent.URI.new!(@agent_uri_str)

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, _pid} ->
            write_template(uri)

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, {:spawn_failed, reason}}
        end
    end
  end

  defp write_template(uri) do
    ctx = %{
      caller: Ezagent.SystemPrincipal.uri("mix-task"),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task"),
      reply: {:caller_inbox, self()}
    }

    content = %{
      name: @agent_name,
      flavor: "cc",
      working_directory: "",
      default_caps: [],
      parent_template_uri: nil,
      created_by: ctx.caller,
      created_at: DateTime.utc_now(),
      soul_slot_values: %{}
    }

    target = Ezagent.URI.with_action(uri, :template, :write)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{content: content},
      ctx: ctx
    })
  end
end
