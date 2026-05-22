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

  ## Phase 7 completion PR-5 — every tool action goes through dispatch + CapBAC

  Pre-PR-5 the tools called `Agent.spawn/4` / `RuleStore.add/5` /
  `DynamicSupervisor.terminate_child` DIRECTLY — bypassing dispatch +
  CapBAC entirely. PR-5 refactors all 7 per the SPEC §2.1 dispatch table:

  - `add_agent_slot` — dispatches `template.instantiate` on the
    AgentTemplate URI (`Ezagent.Behavior.Template` `:instantiate`).
  - `remove_agent_slot` — dispatches `lifecycle.terminate` on the
    worker's instance URI (`Ezagent.Behavior.Lifecycle` `:terminate`).
  - `update_agent_template` — **two-phase rollback-safe**: preflight
    `template.read` → spawn the replacement via `template.instantiate`
    → re-point the working-copy slot → `lifecycle.terminate` the OLD
    worker ONLY after success.
  - `write_matcher` — dispatches `routing.add_rule` on the
    orchestrator's Session URI (`Ezagent.Behavior.Routing` `:add_rule`).
  - `update_template` / `save_template_as` — persist via
    `Ezagent.Entity.SessionTemplate.persist_version/2`, which spawns the
    SessionTemplate Kind + dispatches `Behavior.Template` `:write`.
  - `list_templates` — a per-kind cap-gated read of
    `Ezagent.Ecto.KindSnapshot.list_in_workspace/1`.

  **NO `admin_caps` anywhere in the tool path.** Every dispatch `ctx`
  carries `caps: <the orchestrator's 4 delegated caps>` and `caller:
  <the orchestrator's URI>` — supplied by the orchestrator MCP server
  (`Ezagent.Orchestrator.McpServer`). If a delegated cap is missing the
  dispatch returns `{:error, :unauthorized}` — fail closed, never a
  fallback to ambient authority.

  ## Calling convention

  Every tool takes a trailing `opts` keyword list carrying the
  orchestrator's caller context:

      Tools.add_agent_slot("backend-dev",
        URI.parse("template://agent/default/cc-backend"),
        nil,
        caller: %URI{} = orchestrator_uri,
        caps: caps,
        session_uri: %URI{} = sess,
        workspace_uri: %URI{} = ws)

  Required keys per tool documented at each `@doc`. The orchestrator MCP
  server fills these in from its bound per-orchestrator context before
  invoking — the LLM never supplies caller / caps / session context.

  ## Design locks (CI-gated, see tools_test.exs)

  - Exactly 7 tools (locks against authority creep).
  - No `:fork` tool (Decision #141 — fork is a SessionTemplate
    registry verb, not an in-session orchestrator verb).
  - No `:grant_cap` tool (Decision #137 — cap delegation only
    happens at Generator boot, never mid-session).

  ## Working-copy derivation (Phase 7 completion PR-2 — SPEC §1.3 / §1.6)

  The `template_working_copy` field on the Session's `:chat` slice
  (`Ezagent.Behavior.Chat`) IS the durable source-template record. The
  agent-slot tools (`add_agent_slot` / `remove_agent_slot` /
  `update_agent_template`) maintain `template_working_copy.agent_slots`
  via the `chat.set_working_copy` dispatch.
  """

  require Logger

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Invocation

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

  # === add_agent_slot ====================================================

  @doc """
  Spawn a worker agent in `slot_name` from `agent_template_uri`, by
  dispatching `Ezagent.Behavior.Template` `:instantiate` on the
  AgentTemplate URI (SPEC §2.1 row 1).

  The `:instantiate` action resolves the flavor Class and hands off to
  `Ezagent.Entity.Agent.spawn_from_template_content/4`, which records
  lineage UNDER THE ORCHESTRATOR (`spawned_by: caller`) — so the
  orchestrator's cap #2 (`{:spawned_by, orchestrator}`) later authorizes
  managing the worker.

  Required `opts`:
  - `:caller` — `%URI{}` of the orchestrator (the dispatch `ctx.caller`
    + the `spawned_by` principal for lineage)
  - `:caps` — the orchestrator's delegated cap set (cap #4 gates the
    `template.instantiate`)
  - `:workspace_uri` — `%URI{}` workspace the worker joins; must equal
    the AgentTemplate URI's workspace segment
  - `:session_uri` — `%URI{}` of the orchestrator's session (the
    `agent_slots` slice the worker is recorded into lives here)

  Returns `{:ok, worker_uri}` or `{:error, reason}`.

  `prompt_override` is accepted for API parity with the SPEC but is not
  consumed — the worker's prompt comes from its AgentTemplate's
  `claude_config_dir/settings.json` (Decision #136).
  """
  @spec add_agent_slot(String.t(), URI.t(), String.t() | nil, keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def add_agent_slot(slot_name, %URI{} = agent_template_uri, prompt_override \\ nil, opts \\ [])
      when is_binary(slot_name) do
    _ = prompt_override

    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, worker_uri} <-
           instantiate_worker(agent_template_uri, slot_name, workspace_uri, caller, caps) do
      :ok = upsert_agent_slot(session_uri, slot_name, agent_template_uri, caller, caps)
      {:ok, worker_uri}
    end
  end

  # Dispatch `template.instantiate` on the AgentTemplate Kind. The
  # action runs in-process with the slice in hand, resolves the flavor
  # Class, and spawns the worker — recording lineage under `caller`.
  defp instantiate_worker(%URI{} = agent_template_uri, slot_name, %URI{} = workspace_uri, %URI{} = caller, caps) do
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri) do
      target = URI.parse("#{URI.to_string(agent_template_uri)}?action=template.instantiate")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{
               instance_name: slot_name,
               workspace_uri: workspace_uri,
               spawned_by: caller
             },
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{workers: [worker_uri | _]}} -> {:ok, worker_uri}
        {:ok, %{workers: []}} -> {:error, :instantiate_returned_no_worker}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_instantiate_result, other}}
      end
    end
  end

  # === remove_agent_slot =================================================

  @doc """
  Despawn the worker in `slot_name` by dispatching
  `Ezagent.Behavior.Lifecycle` `:terminate` on the worker's instance URI
  (SPEC §2.1 row 2).

  The worker's instance URI is resolved from the durable
  `template_working_copy.agent_slots` slice. An absent slot is
  idempotent success.

  CapBAC: `lifecycle.terminate` is gated by cap #2
  (`{:spawned_by, orchestrator}`) — the orchestrator may terminate only
  workers it itself spawned.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, :removed}` whether the slot was alive or not (idempotent).
  """
  @spec remove_agent_slot(String.t(), keyword()) :: {:ok, :removed} | {:error, term()}
  def remove_agent_slot(slot_name, opts \\ []) when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      case resolve_slot_worker_uri(session_uri, slot_name, workspace_uri) do
        {:ok, worker_uri} ->
          with :ok <- terminate_worker(worker_uri, caller, caps),
               :ok <- drop_agent_slot(session_uri, slot_name, caller, caps) do
            {:ok, :removed}
          end

        :no_slot ->
          # Absent slot — idempotent success (SPEC §2.1 error mapping).
          {:ok, :removed}
      end
    end
  end

  # Dispatch `lifecycle.terminate` on the worker's instance URI.
  defp terminate_worker(%URI{} = worker_uri, %URI{} = caller, caps) do
    target = URI.parse("#{URI.to_string(worker_uri)}?action=lifecycle.terminate")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: ctx(caller, caps)
         }) do
      {:ok, {:ok, :terminated}} -> :ok
      {:ok, :terminated} -> :ok
      # The worker Kind is not alive — dispatch to an absent / not-ready
      # actor; idempotent termination treats this as already-gone.
      {:error, :no_such_actor} -> :ok
      {:error, :not_ready} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_terminate_result, other}}
    end
  end

  # === update_agent_template =============================================

  @doc """
  Replace the AgentTemplate behind `slot_name` with `new_agent_template_uri`
  — **two-phase, rollback-safe** (SPEC §2.1 row 3, codex rev-5 HIGH-4).

  The pre-PR-5 code did `remove`-then-`add`; a bad new template left the
  slot with no live agent. PR-5 makes it rollback-safe:

  1. **preflight** — dispatch `template.read` on `new_agent_template_uri`,
     cap-checked (cap #4), assert it exists + is populated;
  2. **spawn** the replacement worker via `template.instantiate`;
  3. **atomic swap** — update the working-copy slot tuple to point at
     the new AgentTemplate URI;
  4. **only then** `lifecycle.terminate` the OLD worker.

  Any failure in (1)-(3) aborts — the OLD worker + slot are untouched,
  no outage. A failure in (4) is non-fatal (the new worker is live and
  the slot already points at it); the stale old worker is logged.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, new_worker_uri}` or `{:error, {:update_aborted, reason}}`.
  """
  @spec update_agent_template(String.t(), URI.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def update_agent_template(slot_name, %URI{} = new_agent_template_uri, opts \\ [])
      when is_binary(slot_name) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri) do
      # Capture the OLD worker URI BEFORE any mutation so phase 4 can
      # terminate exactly it (not the new worker).
      old_worker_uri =
        case resolve_slot_worker_uri(session_uri, slot_name, workspace_uri) do
          {:ok, uri} -> uri
          :no_slot -> nil
        end

      with :ok <- preflight_template_read(new_agent_template_uri, caller, caps),
           # Phase 2 — spawn the replacement worker (cap #4).
           {:ok, new_worker_uri} <-
             instantiate_worker(new_agent_template_uri, slot_name, workspace_uri, caller, caps),
           # Phase 3 — atomic swap: the slot tuple now points at the new
           # AgentTemplate URI. From here the slot is "switched";
           # failures past this point do not lose the live new worker.
           :ok <-
             upsert_agent_slot(session_uri, slot_name, new_agent_template_uri, caller, caps) do
        # Phase 4 — terminate the OLD worker (best-effort; the new worker
        # is already the slot's truth). A failed terminate leaves a stale
        # process but never an outage.
        maybe_terminate_old(old_worker_uri, new_worker_uri, caller, caps)
        {:ok, new_worker_uri}
      else
        {:error, reason} ->
          # Phases 1-3 failed — the OLD slot is untouched, no outage.
          {:error, {:update_aborted, reason}}
      end
    end
  end

  # Preflight: dispatch `template.read` on the new AgentTemplate URI,
  # cap-checked (cap #4). Confirms the template exists + is populated
  # BEFORE any destructive step.
  defp preflight_template_read(%URI{} = agent_template_uri, %URI{} = caller, caps) do
    with {:ok, _pid} <- ensure_template_alive(agent_template_uri),
         target <- URI.parse("#{URI.to_string(agent_template_uri)}?action=template.read"),
         {:ok, result} <-
           Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{},
             ctx: ctx(caller, caps)
           }) do
      case result do
        %{content: content} when is_map(content) -> :ok
        %{content: nil} -> {:error, :agent_template_not_populated}
        other -> {:error, {:unexpected_template_read_result, other}}
      end
    end
  end

  # Terminate the OLD worker after a successful swap, unless it IS the
  # new worker (flavors identical + same slot ⇒ identical instance URI ⇒
  # the new worker reused the slot; nothing to terminate).
  defp maybe_terminate_old(nil, _new_worker_uri, _caller, _caps), do: :ok

  defp maybe_terminate_old(%URI{} = old_worker_uri, %URI{} = new_worker_uri, caller, caps) do
    if URI.to_string(old_worker_uri) == URI.to_string(new_worker_uri) do
      :ok
    else
      case terminate_worker(old_worker_uri, caller, caps) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "update_agent_template: new worker live, but terminating old worker " <>
              "#{URI.to_string(old_worker_uri)} failed: #{inspect(reason)} — stale process left"
          )

          :ok
      end
    end
  end

  # === write_matcher =====================================================

  @doc """
  Insert a routing rule that fires `matcher_ast` and delivers to the
  workers named by `receiver_slot_names`, by dispatching
  `Ezagent.Behavior.Routing` `:add_rule` on the orchestrator's Session
  URI (SPEC §2.1 row 4).

  The rule's scope-owning Kind is the orchestrator's Session (invariant
  12 — no `routing-admin://` singleton). CapBAC: gated by cap #1
  (`{:within_session, S}`).

  Receiver slot names are resolved to per-instance worker URIs from the
  durable `template_working_copy.agent_slots`.

  Required `opts`: `:caller`, `:caps`, `:workspace_uri`, `:session_uri`.

  Returns `{:ok, %{id: integer}}` or `{:error, reason}`.
  """
  @spec write_matcher(term(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def write_matcher(matcher_ast, receiver_slot_names, opts \\ [])
      when is_list(receiver_slot_names) do
    with {:ok, caller} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, matcher_json} <- normalize_matcher(matcher_ast),
         {:ok, receiver_uris} <-
           resolve_receiver_uris(session_uri, receiver_slot_names, workspace_uri) do
      target = URI.parse("#{URI.to_string(session_uri)}?action=routing.add_rule")

      case Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{
               table: EzagentDomainChat.Routing.MentionRouting,
               matcher_json: matcher_json,
               receivers: Enum.map(receiver_uris, &URI.to_string/1),
               opts: [workspace_uri: workspace_uri, source: "admin"]
             },
             ctx: ctx(caller, caps)
           }) do
        {:ok, %{id: id}} -> {:ok, %{id: id}}
        {:error, _} = err -> err
        other -> {:error, {:unexpected_add_rule_result, other}}
      end
    end
  end

  # Normalize the matcher into the JSON shape `routing.add_rule` expects.
  # The orchestrator may pass a `{:mention, "x"}` tuple OR an already-
  # JSON-shaped map; both converge to the `Matcher` JSON map.
  defp normalize_matcher(%{} = matcher_json) do
    case Ezagent.Routing.Matcher.from_json(matcher_json) do
      {:ok, _} -> {:ok, matcher_json}
      {:error, _} = err -> err
    end
  end

  defp normalize_matcher(matcher_tuple) when is_tuple(matcher_tuple) do
    json = Ezagent.Routing.Matcher.to_json(matcher_tuple)
    {:ok, json}
  rescue
    _ -> {:error, {:invalid_matcher, matcher_tuple}}
  end

  defp normalize_matcher(other), do: {:error, {:invalid_matcher, other}}

  # === update_template ===================================================

  @doc """
  Snapshot the live session as a NEW VERSION of the current parent
  SessionTemplate, persisting it via
  `Ezagent.Entity.SessionTemplate.persist_version/2` (SPEC §2.1 row 5).

  `persist_version/2` spawns the SessionTemplate Kind at the
  content-hash URI and dispatches `Behavior.Template` `:write` — which
  writes a real `kind_snapshots` row. The version is content-addressed:
  identical content ⇒ identical hash ⇒ idempotent.

  CapBAC: the tool runs `check_template_write_cap/2` (cap #3,
  `:session_template`, `{:within_workspace, ws}`) at the boundary BEFORE
  calling `persist_version/2` — `persist_version/2`'s internal `:write`
  uses admin caps, so the boundary check is what enforces the
  orchestrator's actual authority (SPEC §1.7 caller-context note).

  Required `opts`: `:caller`, `:caps`, `:session_uri`, `:workspace_uri`,
  `:parent_template_uri`.

  Returns `{:ok, new_template_uri}` —
  `template://session/<workspace>/<parent_name>@<new_hash>`. If the
  parent SessionTemplate hash has been deleted, returns
  `{:error, :parent_template_deleted}` (use `save_template_as`).
  """
  @spec update_template(keyword()) :: {:ok, URI.t()} | {:error, term()}
  def update_template(opts \\ []) do
    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, %URI{} = parent_uri} <- require_opt(opts, :parent_template_uri),
         :ok <- check_template_write_cap(caps, workspace_uri),
         :ok <- check_parent_alive(parent_uri),
         {:ok, parent_name} <- extract_template_name(parent_uri),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      content =
        slice
        |> Map.put(:name, parent_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      SessionTemplate.persist_version(content, workspace_uri)
    end
  end

  # Phase 7 PR 48 — parent-template-deletion check. A genuinely-deleted
  # (or never-registered) parent hash returns `:parent_template_deleted`.
  # The lookup is registry-only by design: `SpawnRegistry.spawn` would
  # bring up a FRESH empty SessionTemplate Kind for any URI, masking a
  # real deletion — so the deleted-parent semantics require the
  # live-registry check. For `update_template` the parent IS expected
  # alive: the session was instantiated from it this very session.
  defp check_parent_alive(%URI{} = parent_uri) do
    case Ezagent.KindRegistry.lookup(parent_uri) do
      {:ok, _pid} -> :ok
      :error -> {:error, :parent_template_deleted}
    end
  end

  # === save_template_as ==================================================

  @doc """
  Snapshot the live session as the FIRST VERSION of a NEW SessionTemplate
  named `new_name`, persisting it via
  `Ezagent.Entity.SessionTemplate.persist_version/2` (SPEC §2.1 row 6).

  After persistence, grants the owner a `Behavior.Template`
  SessionTemplate cap on the workspace (SPEC §1.7 (e)) so the owner can
  later instantiate it via the Generator.

  Required `opts`: same as `update_template/1` except
  `:parent_template_uri` is optional (the new template records it as
  lineage when present). `:owner` — the principal who should receive the
  template-create cap (defaults to `:caller` when absent).

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
         {:ok, caps} <- require_opt(opts, :caps),
         :ok <- check_template_write_cap(caps, workspace_uri),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      content =
        slice
        |> Map.put(:name, new_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      case SessionTemplate.persist_version(content, workspace_uri) do
        {:ok, new_uri} ->
          owner_uri = Keyword.get(opts, :owner, caller_uri)
          :ok = grant_owner_template_cap(owner_uri, new_uri, workspace_uri)
          {:ok, new_uri}

        {:error, _} = err ->
          err
      end
    end
  end

  # SPEC §1.7 (e) — after creating a new SessionTemplate, grant the
  # owner a `Behavior.Template` cap on `:session_template` for the
  # workspace so they may later instantiate it (the Generator's
  # owner-cap preflight, §1.4 / PR-4, checks exactly this).
  #
  # The grant dispatches `identity.grant_cap` on the owner's User Kind.
  # The grant itself runs as a system context — the WHO-may-save
  # authority was already enforced by `check_template_write_cap/2` at
  # the tool boundary.
  defp grant_owner_template_cap(%URI{} = owner_uri, %URI{} = _new_template_uri, %URI{} = workspace_uri) do
    cap = %Ezagent.Capability{
      kind: :session_template,
      behavior: Ezagent.Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: DateTime.utc_now()
    }

    target = URI.parse("#{URI.to_string(owner_uri)}?action=identity.grant_cap")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: :ignore
           }
         }) do
      {:ok, _} ->
        :ok

      other ->
        # Non-fatal: the template exists; the cap can be re-granted.
        # §1.7 (e) ordering — template first, cap second.
        Logger.warning(
          "save_template_as: owner template-cap grant failed: #{inspect(other)} — " <>
            "template persisted; owner may need a re-grant to instantiate it"
        )

        :ok
    end
  end

  # === list_templates ====================================================

  @doc """
  List visible templates as
  `%{agent_templates: [URI.t()], session_templates: [URI.t()]}`,
  per-kind cap-gated (SPEC §2.1 row 7 / §1.7 (b)).

  This is the one tool that is a pure read of `kind_snapshots`
  (`Ezagent.Ecto.KindSnapshot.list_in_workspace/1`), NOT a dispatch.
  CapBAC is enforced HERE, **per kind**:

  - AgentTemplate rows are included ONLY if `caps` contains a
    `Behavior.Template` cap matching `kind: :agent_template` (cap #4);
  - SessionTemplate rows are included ONLY if `caps` contains a
    `Behavior.Template` cap matching `kind: :session_template` (cap #3).

  A caller with only cap #4 sees `agent_templates: [...]` and
  `session_templates: []`; a caller with only cap #3 sees the inverse;
  a caller with neither gets `{:error, :unauthorized}`. There is NO
  cross-kind leak and NO `admin_caps` fallback.

  Required `opts`: `:caps`, `:workspace_uri`.

  Optional `name_filter` — substring restricts results.
  """
  @spec list_templates(String.t() | nil, keyword()) ::
          {:ok, %{agent_templates: [URI.t()], session_templates: [URI.t()]}}
          | {:error, term()}
  def list_templates(name_filter \\ nil, opts \\ []) do
    with {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri) do
      agent_allowed? = has_template_cap?(caps, :agent_template, workspace_uri)
      session_allowed? = has_template_cap?(caps, :session_template, workspace_uri)

      if not agent_allowed? and not session_allowed? do
        {:error, :unauthorized}
      else
        rows = snapshot_rows_in_workspace(workspace_uri)

        agents =
          if agent_allowed?,
            do: filter_rows(rows, "agent_template", "agent", name_filter),
            else: []

        sessions =
          if session_allowed?,
            do: filter_rows(rows, "session_template", "session", name_filter),
            else: []

        {:ok, %{agent_templates: agents, session_templates: sessions}}
      end
    end
  end

  defp snapshot_rows_in_workspace(%URI{} = workspace_uri) do
    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
  rescue
    # DB unavailable / no rows — empty catalog.
    _ -> []
  end

  # Partition the snapshot rows by `kind_type`, parse the URI, apply the
  # name filter. Rows whose `kind_type` does not match are dropped.
  defp filter_rows(rows, kind_type, expected_host, name_filter) do
    rows
    |> Enum.filter(fn row -> row.kind_type == kind_type end)
    |> Enum.map(fn row -> URI.parse(row.uri) end)
    |> Enum.filter(&template_match?(&1, expected_host, name_filter))
    |> Enum.sort_by(&URI.to_string/1)
  end

  # === generic invoke ====================================================

  @doc """
  Generic tool invocation entry — dispatches by tool name to the
  corresponding function above. Returns `{:error, {:unknown_tool, name}}`
  for non-listed names (CI gate against silently-added tools).
  """
  @spec invoke(atom(), list()) :: {:ok, term()} | {:error, term()}
  def invoke(tool_name, args) when is_atom(tool_name) and is_list(args) do
    if tool?(tool_name) do
      apply(__MODULE__, tool_name, args)
    else
      {:error, {:unknown_tool, tool_name}}
    end
  end

  # === internals =========================================================

  # The dispatch ctx for every tool action — the orchestrator's URI as
  # `caller`, its delegated caps as `caps`. NEVER `admin_caps`. A missing
  # delegated cap means CapBAC denies — fail closed.
  defp ctx(%URI{} = caller, caps) do
    %{
      caller: caller,
      caps: to_cap_set(caps),
      reply: {:caller_inbox, self()}
    }
  end

  defp to_cap_set(%MapSet{} = caps), do: caps
  defp to_cap_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp to_cap_set(_), do: MapSet.new()

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  defp ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Ezagent.SpawnRegistry.spawn(template_uri) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  # The per-kind cap check for `list_templates` / template-write tools.
  # Builds the same `needed` shape CapBAC uses (a representative
  # workspace template URI) and checks `Capability.matches?/2` — so the
  # MCP-boundary check stays structurally aligned with dispatch CapBAC.
  defp has_template_cap?(caps, kind, %URI{} = workspace_uri) do
    workspace_name = workspace_uri.host || "default"

    representative =
      case kind do
        :agent_template -> URI.new!("template://agent/#{workspace_name}/_catalog")
        :session_template -> URI.new!("template://session/#{workspace_name}/_catalog@_")
      end

    needed = %{
      kind: kind,
      behavior: Ezagent.Behavior.Template,
      instance: representative,
      workspace_uri: workspace_uri
    }

    caps
    |> to_cap_set()
    |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
  end

  # Tool-boundary cap check for `update_template` / `save_template_as` —
  # both need cap #3 (`:session_template` `Behavior.Template`).
  defp check_template_write_cap(caps, %URI{} = workspace_uri) do
    if has_template_cap?(caps, :session_template, workspace_uri) do
      :ok
    else
      {:error, :unauthorized}
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

  # --- working-copy slice maintenance (SPEC §1.6) ------------------------

  # Append/replace `{slot_name, agent_template_uri}` in the durable
  # `template_working_copy.agent_slots` slice via `chat.set_working_copy`.
  defp upsert_agent_slot(%URI{} = session_uri, slot_name, %URI{} = agent_template_uri, %URI{} = caller, caps) do
    wc = read_template_working_copy(session_uri)
    slots = Map.get(wc, :agent_slots, [])

    new_slots =
      slots
      |> Enum.reject(fn {s, _uri} -> to_string(s) == slot_name end)
      |> Kernel.++([{slot_name, agent_template_uri}])

    write_working_copy(session_uri, Map.put(wc, :agent_slots, new_slots), caller, caps)
  end

  # Drop the `{slot_name, _}` tuple from `agent_slots`.
  defp drop_agent_slot(%URI{} = session_uri, slot_name, %URI{} = caller, caps) do
    wc = read_template_working_copy(session_uri)
    slots = Map.get(wc, :agent_slots, [])

    new_slots = Enum.reject(slots, fn {s, _uri} -> to_string(s) == slot_name end)

    write_working_copy(session_uri, Map.put(wc, :agent_slots, new_slots), caller, caps)
  end

  defp write_working_copy(%URI{} = session_uri, working_copy, %URI{} = caller, caps) do
    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.set_working_copy")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{template_working_copy: working_copy},
           ctx: ctx(caller, caps)
         }) do
      {:ok, %{template_working_copy: _}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # Resolve a slot's per-instance worker URI from its source
  # AgentTemplate URI (which carries the `flavor`) + the slot name.
  defp resolve_slot_worker_uri(%URI{} = session_uri, slot_name, %URI{} = workspace_uri) do
    wc = read_template_working_copy(session_uri)
    slots = Map.get(wc, :agent_slots, [])

    case Enum.find(slots, fn {s, _uri} -> to_string(s) == slot_name end) do
      {_s, %URI{} = agent_template_uri} ->
        {:ok, worker_uri_for(agent_template_uri, slot_name, workspace_uri)}

      {_s, uri} when is_binary(uri) ->
        {:ok, worker_uri_for(URI.parse(uri), slot_name, workspace_uri)}

      nil ->
        :no_slot
    end
  end

  # The worker instance URI for a slot: `entity://agent/<ws>/<flavor>_<slot>`
  # (SPEC §1.2). The flavor must match what `template.instantiate`'s
  # `resolve_instance_uri/4` built.
  defp worker_uri_for(%URI{} = agent_template_uri, slot_name, %URI{} = workspace_uri) do
    workspace_name = workspace_uri.host || "default"
    flavor = flavor_of_agent_template(agent_template_uri)

    if is_binary(flavor) and flavor != "" do
      URI.new!("entity://agent/#{workspace_name}/#{flavor}_#{slot_name}")
    else
      URI.new!("entity://agent/#{workspace_name}/#{slot_name}")
    end
  end

  # Derive the flavor from the AgentTemplate's `:template` slice if the
  # Kind is alive, else default to "cc" (the V1 flavor). The
  # `:instantiate` action built the worker URI with this same flavor
  # prefix, so the two must agree.
  defp flavor_of_agent_template(%URI{} = agent_template_uri) do
    case Ezagent.KindRegistry.lookup(agent_template_uri) do
      {:ok, pid} ->
        slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(:template, %{})

        case Map.get(slice, :content) do
          content when is_map(content) ->
            Map.get(content, :flavor) || Map.get(content, "flavor") || "cc"

          _ ->
            "cc"
        end

      :error ->
        "cc"
    end
  rescue
    _ -> "cc"
  end

  defp resolve_receiver_uris(%URI{} = session_uri, slot_names, %URI{} = workspace_uri) do
    uris =
      slot_names
      |> Enum.map(fn slot ->
        case resolve_slot_worker_uri(session_uri, to_string(slot), workspace_uri) do
          {:ok, worker_uri} -> worker_uri
          :no_slot -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if uris == [] do
      {:error, :no_resolvable_receivers}
    else
      {:ok, uris}
    end
  end

  # Phase 7 completion PR-2 (SPEC §1.3 / §1.6) — build the
  # template-shaped working-copy slice from the durable
  # `template_working_copy` field on the live Session's `:chat` slice.
  # `session_uri` and `name` are deliberately ABSENT from the emitted
  # slice so two different sessions with an identical team config hash
  # identically.
  defp build_working_copy(%URI{} = session_uri, %URI{} = workspace_uri, %URI{} = _caller_uri, parent_uri) do
    wc = read_template_working_copy(session_uri)

    orchestrator_template_uri =
      Map.get(wc, :orchestrator_template_uri) ||
        URI.parse("template://agent/default/cc-orchestrator")

    default_workspace_uri = Map.get(wc, :default_workspace_uri) || workspace_uri

    slice = %{
      description: Map.get(wc, :description, ""),
      agent_slots: Enum.sort(Map.get(wc, :agent_slots, [])),
      orchestrator_template_uri: orchestrator_template_uri,
      routing_rules: Enum.sort(Map.get(wc, :routing_rules, [])),
      default_workspace_uri: default_workspace_uri,
      parent_template_uri: parent_uri
    }

    {:ok, slice}
  end

  # Read the durable `template_working_copy` field off the live Session
  # Kind's `:chat` slice. A Session not alive, or whose `:chat` slice
  # predates PR-2, yields the empty default.
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
