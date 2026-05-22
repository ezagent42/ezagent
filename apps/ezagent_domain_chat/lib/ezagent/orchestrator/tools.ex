defmodule Ezagent.Orchestrator.Tools do
  @moduledoc """
  Orchestrator MCP tool surface — the 7 tools the cc-orchestrator
  (Decision #136, SPEC §7-3) exposes to the LLM it hosts.

  ## The 7 tools

  | Tool | Args | Effect |
  |---|---|---|
  | `add_agent_slot` | slot_name, agent_template_uri, optional prompt_override | Spawns a worker agent from template |
  | `remove_agent_slot` | slot_name | Despawns the worker |
  | `update_agent_template` | slot_name, new_agent_template_uri | Replaces an agent slot's template (re-spawn) |
  | `write_matcher` | matcher_ast, receiver_slot_names | Inserts routing rule into the live RuleStore |
  | `update_template` | (no args) | Snapshot current session state → new version of current parent SessionTemplate |
  | `save_template_as` | new_name | Snapshot current session state → first version of NEW SessionTemplate |
  | `list_templates` | optional name_filter | Returns visible AgentTemplate + SessionTemplate URIs (CapBAC-filtered) |

  ## Calling convention

  Every tool takes a trailing `opts` keyword list carrying the
  orchestrator's session context:

      Tools.add_agent_slot("backend-dev",
        URI.parse("template://agent/default/cc-orchestrator"),
        opts: [
          session_uri: %URI{} = sess,
          workspace_uri: %URI{} = ws,
          caller: %URI{} = orchestrator_uri,
          owner: %URI{} = owner_uri,
          caps: caps
        ])

  Required keys per tool documented at each `@doc`. The MCP bridge
  hosting the orchestrator fills these in before dispatching.

  ## Design locks (CI-gated, see tools_test.exs)

  - Exactly 7 tools (locks against authority creep).
  - No `:fork` tool (Decision #141 — fork is a SessionTemplate
    registry verb, not an in-session orchestrator verb).
  - No `:grant_cap` tool (Decision #137 — cap delegation only
    happens at Generator boot, never mid-session).

  ## Working-copy derivation (Phase 7 completion PR-2 — SPEC §1.3 / §1.6)

  The `template_working_copy` field on the Session's `:chat` slice
  (`Ezagent.Behavior.Chat`) IS the durable source-template record.
  `build_working_copy/4` reads it **straight from the live Session
  Kind's `:chat` slice** — it does NOT derive `agent_slots` from live
  `Ezagent.WorkspaceRegistry` membership and does NOT derive
  `routing_rules` from live `Ezagent.Routing.RuleStore` rows.

  The slice it emits is **template-shaped** (codex rev-3 HIGH-3), not
  live-runtime shaped:

  - `agent_slots :: [{slot_name, template://agent/<ws>/<name>}]` — each
    slot's durable `source_agent_template_uri`, NOT a live
    `entity://agent` instance URI.
  - `routing_rules :: [{matcher_ast, [slot_name]}]` — receivers are
    slot NAMES, not live agent URIs.

  The hash-input map passed to
  `Ezagent.Entity.SessionTemplate.compute_version_hash/1` EXCLUDES
  `session_uri` and `name` (and the function itself already drops
  `created_at` / `created_by`) — so two different sessions with an
  identical team config hash identically.

  A Session whose `:chat` slice predates PR-2 (no
  `template_working_copy` key) reads through
  `Ezagent.Behavior.Chat.template_working_copy/1`, which returns the
  empty default — `build_working_copy/4` then emits an empty
  template-shaped slice rather than crashing.
  """

  require Logger

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.{Agent, SessionTemplate}
  alias Ezagent.Routing.RuleStore

  @doc "The 7 orchestration tool names. CI gate test pins this list at 7."
  @spec tool_names() :: [atom()]
  def tool_names do
    [
      :add_agent_slot,
      :remove_agent_slot,
      :update_agent_template,
      :write_matcher,
      :update_template,
      :save_template_as,
      :list_templates
    ]
  end

  @doc "True iff `name` is one of the 7 declared orchestration tools."
  @spec tool?(atom()) :: boolean()
  def tool?(name) when is_atom(name), do: name in tool_names()
  def tool?(_), do: false

  # --- tools (PR 46-impl bodies) -----------------------------------------

  @doc """
  Spawn a worker agent at `entity://agent/<slot_name>` from `agent_template_uri`.

  Required `opts`:
  - `:workspace_uri` — `%URI{}` workspace the agent joins
  - `:owner` — `%URI{}` principal whose lineage the spawn records
    (typically the human owner who triggered the session, so the
    orchestrator's `{:spawned_by, owner}` cap shape resolves correctly)

  Returns `{:ok, agent_uri}` or `{:error, reason}`.

  `prompt_override` is accepted for API parity with the SPEC but is
  not consumed today — the agent's prompt comes from its AgentTemplate's
  `claude_config_dir/settings.json` (Decision #136, AgentTemplate is a
  pointer, not a prompt store).
  """
  @spec add_agent_slot(String.t(), URI.t(), String.t() | nil, keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def add_agent_slot(slot_name, %URI{} = agent_template_uri, prompt_override \\ nil, opts \\ [])
      when is_binary(slot_name) do
    with {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, owner_uri} <- require_opt(opts, :owner) do
      _ = prompt_override

      Agent.spawn(agent_template_uri, slot_name, workspace_uri, owner_uri)
    end
  end

  @doc """
  Despawn the worker at `entity://agent/<slot_name>` if alive.

  Returns `{:ok, :removed}` whether the slot was alive or not (idempotent).
  """
  @spec remove_agent_slot(String.t(), keyword()) :: {:ok, :removed}
  def remove_agent_slot(slot_name, _opts \\ []) when is_binary(slot_name) do
    # Phase 9 PR-2 (SPEC v3 §3): defaulting to `default` workspace
    # until orchestrator-side workspace plumbing lands in a later PR.
    agent_uri = URI.new!("entity://agent/default/#{slot_name}")

    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, pid} ->
        _ =
          DynamicSupervisor.terminate_child(EzagentDomainChat.AgentSupervisor, pid)

      :error ->
        :ok
    end

    {:ok, :removed}
  end

  @doc """
  Replace an agent slot's template: despawn the live agent at
  `entity://agent/<slot_name>`, then respawn from `new_agent_template_uri`.

  Required `opts`: same as `add_agent_slot/4` (`:workspace_uri`,
  `:owner`).
  """
  @spec update_agent_template(String.t(), URI.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def update_agent_template(slot_name, %URI{} = new_agent_template_uri, opts \\ [])
      when is_binary(slot_name) do
    {:ok, :removed} = remove_agent_slot(slot_name)
    add_agent_slot(slot_name, new_agent_template_uri, nil, opts)
  end

  @doc """
  Insert a routing rule that fires `matcher_ast` against incoming
  messages and delivers to the agents named by `receiver_slot_names`
  (each becomes `entity://agent/<slot_name>`).

  Required `opts`:
  - `:workspace_uri` — scopes the rule (Phase 7 PR 31 workspace
    isolation; rules without a workspace_uri match every workspace
    and break isolation invariants)
  - `:caller` — `%URI{}` of the orchestrator (recorded as `created_by`
    on the rule row for audit)

  Returns `{:ok, %RuleStore{}}` or `{:error, reason}`.
  """
  @spec write_matcher(term(), [String.t()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def write_matcher(matcher_ast, receiver_slot_names, opts \\ [])
      when is_list(receiver_slot_names) do
    with {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller) do
      receivers =
        Enum.map(receiver_slot_names, fn slot ->
          # Phase 9 PR-2 (SPEC v3 §3): defaulting to `default` workspace
          # until orchestrator-side workspace plumbing lands.
          URI.new!("entity://agent/default/#{slot}")
        end)

      RuleStore.add(
        Ezagent.Routing.MentionRouting,
        matcher_ast,
        receivers,
        caller_uri,
        workspace_uri: workspace_uri
      )
    end
  end

  @doc """
  Snapshot the live session state as a NEW VERSION of the current
  parent SessionTemplate. Hash-derived URI per Decision #143
  (SHA-256 over slice content); two equivalent snapshots produce
  the same hash (content-addressed).

  Required `opts`:
  - `:session_uri` — `%URI{}` of the orchestrator's session
  - `:workspace_uri` — `%URI{}` workspace the live state lives in
  - `:caller` — `%URI{}` orchestrator (becomes `created_by`)
  - `:parent_template_uri` — `%URI{}` of the SessionTemplate the
    current session was instantiated from. nil for sessions not
    spawned from a template (in which case use `save_template_as`
    instead).

  Returns `{:ok, new_template_uri}` where the URI is
  `template://session/<workspace>/<parent_name>@<new_hash>`.

  ## Deleted parent (PR 48)

  If the parent SessionTemplate hash has been deleted from the
  registry since this session was instantiated, returns
  `{:error, :parent_template_deleted}`. The running session continues
  on its working-copy (orchestrator stays alive); the orchestrator
  must `save_template_as/2` under a new name to persist its refinements
  going forward. Per SPEC §7-3 "in-flight template-deletion semantics".
  """
  @spec update_template(keyword()) :: {:ok, URI.t()} | {:error, term()}
  def update_template(opts \\ []) do
    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, %URI{} = parent_uri} <- require_opt(opts, :parent_template_uri),
         :ok <- check_parent_alive(parent_uri),
         {:ok, parent_name} <- extract_template_name(parent_uri),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      version_hash = SessionTemplate.compute_version_hash(slice)
      # SPEC v3 §3.6 PR-7 — new template URI lands in same workspace
      # as the orchestrator's session.
      new_uri =
        SessionTemplate.build_uri(parent_name, version_hash, workspace: workspace_uri.host)

      {:ok, new_uri}
    end
  end

  # Phase 7 PR 48 — parent-template-deletion check. Returns :ok if the
  # parent SessionTemplate hash is still registered in KindRegistry,
  # {:error, :parent_template_deleted} if it's gone.
  #
  # `save_template_as/2` deliberately does NOT call this — saving as
  # a NEW name should always work even if the original parent is
  # deleted (the new template just records the dead parent as its
  # lineage anchor, marking the heritage without depending on it).
  defp check_parent_alive(%URI{} = parent_uri) do
    case Ezagent.KindRegistry.lookup(parent_uri) do
      {:ok, _pid} -> :ok
      :error -> {:error, :parent_template_deleted}
    end
  end

  @doc """
  Snapshot the live session state as the FIRST VERSION of a NEW
  SessionTemplate named `new_name`. Used when the orchestrator wants
  to start a new template family from a refined session, rather than
  bumping the version of the parent.

  Required `opts`: same as `update_template/1` except
  `:parent_template_uri` is optional — when nil, the new template
  has no lineage.

  Returns `{:ok, new_template_uri}`.
  """
  @spec save_template_as(String.t(), keyword()) :: {:ok, URI.t()} | {:error, term()}
  def save_template_as(new_name, opts \\ []) when is_binary(new_name) and new_name != "" do
    parent_uri =
      case Keyword.get(opts, :parent_template_uri) do
        %URI{} = u -> u
        _ -> nil
      end

    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      version_hash = SessionTemplate.compute_version_hash(slice)
      # SPEC v3 §3.6 PR-7 — new template URI lands in same workspace
      # as the orchestrator's session.
      new_uri =
        SessionTemplate.build_uri(new_name, version_hash, workspace: workspace_uri.host)

      {:ok, new_uri}
    end
  end

  @doc """
  List visible templates as
  `%{agent_templates: [URI.t()], session_templates: [URI.t()]}`.

  Filters via the registered Kind list (queries `KindRegistry`).
  Optional `name_filter` substring restricts results.

  CapBAC filtering (template:read per template) is deferred to the
  MCP bridge that calls this tool — it knows the caller's caps and
  can drop URIs the caller can't read before handing the list to
  the LLM. This function returns the raw catalog.
  """
  @spec list_templates(String.t() | nil, keyword()) ::
          {:ok, %{agent_templates: [URI.t()], session_templates: [URI.t()]}}
  def list_templates(name_filter \\ nil, _opts \\ []) do
    all_uris =
      Ezagent.KindRegistry.list_all()
      |> Enum.map(fn {uri_str, _pid} -> URI.parse(uri_str) end)

    agents =
      all_uris
      |> Enum.filter(&template_match?(&1, "agent", name_filter))
      |> Enum.sort_by(&URI.to_string/1)

    sessions =
      all_uris
      |> Enum.filter(&template_match?(&1, "session", name_filter))
      |> Enum.sort_by(&URI.to_string/1)

    {:ok, %{agent_templates: agents, session_templates: sessions}}
  end

  @doc """
  Generic tool invocation entry — dispatches by tool name to the
  corresponding function above. Returns `{:error, {:unknown_tool, name}}`
  for non-listed names (CI gate against silently-added tools).

  `args` is the positional arg list ending with the opts keyword list
  (e.g. `[slot_name, template_uri, prompt_override, opts]`).
  """
  @spec invoke(atom(), list()) :: {:ok, term()} | {:error, term()}
  def invoke(tool_name, args) when is_atom(tool_name) and is_list(args) do
    if tool?(tool_name) do
      apply(__MODULE__, tool_name, args)
    else
      {:error, {:unknown_tool, tool_name}}
    end
  end

  # --- internals --------------------------------------------------------

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  defp template_match?(%URI{scheme: "template", host: host} = uri, expected_host, nil) do
    host == expected_host and is_binary(uri.path)
  end

  defp template_match?(%URI{scheme: "template", host: _host, path: path} = uri, expected_host, filter)
       when is_binary(filter) do
    template_match?(uri, expected_host, nil) and
      (path != nil and String.contains?(path, filter))
  end

  defp template_match?(_, _, _), do: false

  defp extract_template_name(%URI{scheme: "template", host: "session", path: path})
       when is_binary(path) do
    # SPEC v3 §3.6 (Phase 9 PR-7) — path is "/<workspace>/<name>@<hash>"
    # (PR-7 added the workspace segment).
    case String.split(path, "/", trim: true) do
      [_workspace, name_with_hash | _] ->
        name = name_with_hash |> String.split("@") |> hd()

        if name == "" do
          {:error, :template_name_empty}
        else
          {:ok, name}
        end

      _ ->
        {:error, :template_name_empty}
    end
  end

  defp extract_template_name(other), do: {:error, {:not_a_session_template_uri, other}}

  # Phase 7 completion PR-2 (SPEC §1.3 / §1.6) — build the
  # template-shaped working-copy slice from the durable
  # `template_working_copy` field on the live Session's `:chat` slice.
  #
  # This is NOT a live-runtime derivation: `agent_slots` and
  # `routing_rules` come straight from the durable field (populated by
  # the Generator + the orchestrator slot tools in PR-4 / PR-5), so a
  # worker that died and respawned still carries its slot's
  # `source_agent_template_uri`, and routing receivers stay slot
  # NAMES. The emitted slice is the input to
  # `SessionTemplate.compute_version_hash/1`; `session_uri` and `name`
  # are deliberately ABSENT from it so two different sessions with an
  # identical team config hash identically.
  defp build_working_copy(%URI{} = session_uri, %URI{} = workspace_uri, %URI{} = caller_uri, parent_uri) do
    wc = read_template_working_copy(session_uri)

    orchestrator_template_uri =
      Map.get(wc, :orchestrator_template_uri) ||
        URI.parse("template://agent/default/cc-orchestrator")

    default_workspace_uri = Map.get(wc, :default_workspace_uri) || workspace_uri

    # The hash-input map. `compute_version_hash/1` already drops
    # `created_at`/`created_by`/`version_hash`/`version_tag`; PR-2 also
    # structures the map so `session_uri` and `name` are ABSENT — they
    # never enter the hash, so identical team configs across distinct
    # sessions produce the SAME hash (SPEC §1.3).
    slice = %{
      description: Map.get(wc, :description, ""),
      # [{slot_name, template://agent/<ws>/<name>}] — the durable
      # source_agent_template_uri per slot (NOT live entity://agent).
      agent_slots: Enum.sort(Map.get(wc, :agent_slots, [])),
      orchestrator_template_uri: orchestrator_template_uri,
      # [{matcher_ast, [slot_name]}] — receivers are slot NAMES.
      routing_rules: Enum.sort(Map.get(wc, :routing_rules, [])),
      default_workspace_uri: default_workspace_uri,
      parent_template_uri: parent_uri,
      # created_by is dropped by compute_version_hash/1 — carried here
      # for the eventual persisted SessionTemplate content (PR-3).
      created_by: caller_uri
    }

    {:ok, slice}
  end

  # Read the durable `template_working_copy` field off the live Session
  # Kind's `:chat` slice. A Session that is not alive, or whose `:chat`
  # slice predates PR-2 (no `template_working_copy` key), yields the
  # empty default via `Chat.template_working_copy/1` — `build_working_copy/4`
  # then emits an empty template-shaped slice rather than crashing.
  defp read_template_working_copy(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Chat.state_slice(), %{})

        Chat.template_working_copy(chat_slice)

      :error ->
        Chat.default_template_working_copy()
    end
  end
end
