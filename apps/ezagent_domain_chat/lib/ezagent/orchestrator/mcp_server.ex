defmodule Ezagent.Orchestrator.McpServer do
  @moduledoc """
  Orchestrator MCP server — the privileged command surface a live
  `claude` orchestrator reaches the 7 `Ezagent.Orchestrator.Tools`
  through (Phase 7 completion SPEC §2 "PR-5").

  ## What this module is

  A per-orchestrator-agent component that:

  1. **Holds the caller context** — the calling orchestrator's URI +
     its FOUR delegated caps (§1.4). Every tool call this server
     executes runs the underlying `Tools` function with that URI as
     `ctx.caller` and those caps as `ctx.caps`. **No tool runs with
     ambient `admin_caps`** — a missing delegated cap means the
     dispatched action returns `{:error, :unauthorized}`, which this
     server surfaces as a structured MCP tool error.
  2. **Holds the session context** — the orchestrator's session URI +
     workspace URI, bound at construction (`new/1` / the GenServer
     `init/1`). Tools read the session/workspace from this bound
     context, **never from tool-call args** — the LLM cannot point a
     tool at a different session.
  3. **Owns the tool JSON schemas** — `tool_schemas/0` returns the
     MCP `tools/list`-shaped descriptor for all 7 tools.
  4. **Maps the result** — a tool `{:ok, _}` becomes an MCP success
     content block; a `{:error, _}` becomes a structured MCP tool
     error (`%{error: %{...}}`) the orchestrator LLM sees and can
     surface in chat.

  ## How a live `claude` orchestrator reaches it

  A `claude` agent talks to MCP servers listed in its `--mcp-config`
  file. The cc Template Class (`Ezagent.PluginCc.Template.CcAgent`)
  already emits a trusted esr-bridge `--mcp-config`
  and accepts an ADDITIONAL operator
  `--mcp-config` (`operator_mcp_config_path`, §1.5 (c) — additive, the
  bridge is never removed). The cc-orchestrator AgentTemplate's
  `mcp_config_path` field points at an orchestrator MCP-server config
  whose stdio command runs a thin Python bridge (the same shape as
  `ezagent_mcp_bridge.py`) that:

  - presents `tool_schemas/0` on `tools/list`;
  - on `tools/call`, forwards `{tool, arguments}` to the orchestrator's
    ESR-side `McpServer` over the existing WebSocket channel;
  - the ESR side runs `handle_tool_call/2` against THIS server's bound
    context and returns the structured result.

  The orchestrator MCP server therefore reuses the cc bridge's WS
  transport — it is a second logical MCP server multiplexed over the
  same channel, not a second socket. The caller/cap/session context is
  bound ESR-side (here), never trusted from the wire.

  ## The bound context — a plain struct OR a GenServer

  `Ezagent.Orchestrator.McpServer` is usable two ways:

  - **As a value** — `new/1` builds an immutable `%McpServer{}` context
    struct; `handle_tool_call/3` executes a tool against it. This is
    the deterministic, side-effect-free core the fake-LLM/fake-MCP e2e
    drives.
  - **As a process** — `start_link/1` runs a GenServer that holds a
    `%McpServer{}` and answers `tool_call/3` casts/calls. The process
    form is what a long-lived orchestrator session uses; the value form
    is what tests use. Both share `handle_tool_call/3`.

  The context is refreshed lazily: `new/1` loads the orchestrator's caps
  via `Ezagent.Identity.list_caps_for/1` (the agent Kind's `:identity`
  slice). `refresh_caps/1` reloads them — caps are granted once at
  Generator boot (§1.4) and never change mid-session, so a single load
  at construction is the norm.
  """

  use GenServer

  require Logger

  alias Ezagent.Orchestrator.Tools

  @enforce_keys [:orchestrator_uri, :session_uri, :workspace_uri, :caps]
  defstruct [:orchestrator_uri, :session_uri, :workspace_uri, :caps, :owner_uri, :parent_template_uri]

  @type t :: %__MODULE__{
          orchestrator_uri: URI.t(),
          session_uri: URI.t(),
          workspace_uri: URI.t(),
          caps: MapSet.t(Ezagent.Capability.t()),
          owner_uri: URI.t() | nil,
          parent_template_uri: URI.t() | nil
        }

  # --- construction ------------------------------------------------------

  @doc """
  Build the bound per-orchestrator MCP-server context (value form).

  Required opts:
  - `:orchestrator_uri` — `%URI{}` of the orchestrator agent
  - `:session_uri` — `%URI{}` of the orchestrator's session
  - `:workspace_uri` — `%URI{}` workspace the session lives in

  Optional opts:
  - `:owner_uri` — `%URI{}` the human owner (for `save_template_as`
    owner-cap grant; defaults to the orchestrator's own URI)
  - `:parent_template_uri` — `%URI{}` SessionTemplate the session was
    instantiated from (for `update_template`)
  - `:caps` — pre-loaded cap set; when absent the orchestrator's caps
    are loaded via `Ezagent.Identity.list_caps_for/1`

  The orchestrator's caps are the FOUR delegated caps the Generator
  granted at session boot (§1.4) — loaded from the agent Kind's
  `:identity` slice, NOT `admin_caps`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, orchestrator_uri} <- fetch_uri(opts, :orchestrator_uri),
         {:ok, session_uri} <- fetch_uri(opts, :session_uri),
         {:ok, workspace_uri} <- fetch_uri(opts, :workspace_uri) do
      caps =
        case Keyword.get(opts, :caps) do
          %MapSet{} = set -> set
          list when is_list(list) -> MapSet.new(list)
          nil -> load_caps(orchestrator_uri)
        end

      {:ok,
       %__MODULE__{
         orchestrator_uri: orchestrator_uri,
         session_uri: session_uri,
         workspace_uri: workspace_uri,
         caps: caps,
         owner_uri: Keyword.get(opts, :owner_uri, orchestrator_uri),
         parent_template_uri: Keyword.get(opts, :parent_template_uri)
       }}
    end
  end

  @doc """
  Build the bound context for `orchestrator_uri` ALONE — the entry
  point the orchestrator MCP transport bridge's Channel
  (`Ezagent.Orchestrator.McpChannel`) uses.

  A `claude`-launched bridge can only present the orchestrator's agent
  URI (token-authenticated by `Ezagent.Orchestrator.McpSocket`). It
  cannot — and must not — supply the session / workspace / caps: that
  is exactly the context an untrusted process could spoof. So this
  function resolves the rest SERVER-SIDE:

  - session / workspace / owner / parent-template come from
    `Ezagent.Orchestrator.McpRegistry.lookup/1` — the binding the
    Generator registered when it spawned the orchestrator into a
    session.
  - the four delegated caps are loaded from the orchestrator agent's
    own `:identity` slice via `Ezagent.Identity.list_caps_for/1`
    (inside `new/1`), NEVER from the wire.

  Returns `{:error, :orchestrator_not_registered}` when the
  orchestrator has no `McpRegistry` row AND its context cannot be
  rebuilt from durable state — a `claude` process whose agent URI is
  valid but which is not (and never was) a registered orchestrator
  cannot reach the 7 tools (fail-closed).

  ## Read-through cache (Task #110 structural fix)

  `McpRegistry` is a CACHE, not the source of truth. The durable source
  of truth is the Session's `kind_snapshots` row (Session is
  `{:snapshot, :on_change}`). On a phx restart the ETS table is empty,
  but the snapshot survives — so an ETS MISS does NOT mean "not an
  orchestrator". This function LAZILY REBUILDS the context from the
  durable Session snapshot on a miss and fills the cache, eliminating
  the entire "registration lost on restart" failure class. Only when
  no durable Session snapshot maps back to this orchestrator URI (or
  that session genuinely has no orchestrator) do we fail-closed.
  """
  @spec from_orchestrator_uri(URI.t()) :: {:ok, t()} | {:error, term()}
  def from_orchestrator_uri(%URI{} = orchestrator_uri) do
    case Ezagent.Orchestrator.McpRegistry.lookup(orchestrator_uri) do
      {:ok, ctx} ->
        build_from_context(orchestrator_uri, ctx)

      :error ->
        rebuild_from_durable(orchestrator_uri)
    end
  end

  # Construct the bound `%McpServer{}` from a registry context map.
  # Shared by the cache-HIT path and the lazy-rebuild cache-fill path.
  defp build_from_context(%URI{} = orchestrator_uri, ctx) do
    new(
      orchestrator_uri: orchestrator_uri,
      session_uri: ctx.session_uri,
      workspace_uri: ctx.workspace_uri,
      owner_uri: ctx.owner_uri || orchestrator_uri,
      parent_template_uri: ctx.parent_template_uri,
      # Caps are the orchestrator agent's OWN four delegated caps —
      # loaded server-side from its `:identity` slice. Passing them
      # explicitly (rather than letting `new/1` fall back to
      # `Ezagent.Identity.list_caps_for/1`, which is user-kind
      # scoped) keeps the load reliable for an `:agent` Kind.
      caps: load_orchestrator_caps(orchestrator_uri)
    )
  end

  # --- lazy rebuild from durable state (Task #110) -----------------------

  # ETS MISS path: rebuild the orchestrator context from the Session's
  # durable `kind_snapshots` row, then fill the cache.
  #
  # Reads the PERSISTED snapshot (not the live Session Kind state)
  # deliberately: the orchestrator bridge may join `orch:bridge:<uri>`
  # before the Session Kind has cold-spawned, and the Session is a
  # distinct lifecycle (it may not be running at all). The snapshot row
  # exists the moment `EzagentDomainChat.create_session/3` first
  # persisted it (step-4 materialization + the Session's
  # `{:snapshot, :on_change}` write) and survives the restart that
  # emptied ETS — so reading it works regardless of whether the Session
  # Kind is currently alive.
  #
  # Returns `{:error, :orchestrator_not_registered}` when no durable
  # Session snapshot maps back to this orchestrator URI, or that session
  # genuinely has no orchestrator (no `:orchestrator_template_uri` on its
  # durable working copy). That is a LEGITIMATE fail-closed — a valid
  # agent URI that is not an orchestrator — NOT a degrade path.
  defp rebuild_from_durable(%URI{} = orchestrator_uri) do
    with {:ok, session_uri, workspace_uri} <- resolve_session(orchestrator_uri),
         {:ok, chat_slice} <- load_chat_slice(session_uri),
         {:ok, wc} <- orchestrator_working_copy(chat_slice) do
      owner_uri = Map.get(chat_slice, :owner_uri)
      parent_template_uri = recover_parent_template_uri(wc, session_uri, owner_uri, workspace_uri)

      ctx = %{
        session_uri: session_uri,
        workspace_uri: workspace_uri,
        owner_uri: owner_uri,
        parent_template_uri: parent_template_uri
      }

      # Cache-fill. ETS `:set` put is atomic, so concurrent joins racing
      # the same rebuild simply overwrite an identical row — no torn
      # state. We deliberately register even when caps load lazily inside
      # `build_from_context/2`: the row carries only session/workspace/
      # owner/parent context (never caps), which are pure functions of
      # the durable snapshot and so identical across racers.
      _ = Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri, Map.to_list(ctx))

      build_from_context(orchestrator_uri, ctx)
    else
      _ -> {:error, :orchestrator_not_registered}
    end
  end

  # Recover (session_uri, workspace_uri) from the orchestrator URI — the
  # inverse of `Ezagent.Entity.Session.derive_orchestrator_uri/2`.
  #
  # The orchestrator URI is `entity://agent/<ws>/cc_orchestrator-<disc>`
  # where `<disc>` is the Session URI's NAME segment. The workspace is
  # the orchestrator URI's own workspace (entity scheme → host). The
  # Session's CLASS segment (`session://<class>/<ws>/<disc>`) is NOT
  # encoded in the orchestrator URI, so we cannot reconstruct the exact
  # Session URI string by formatting — instead we enumerate the durable
  # `session`-type snapshots in that workspace and match the one whose
  # `derive_orchestrator_uri/2` round-trips to this orchestrator URI.
  # Deterministic + class-agnostic.
  defp resolve_session(%URI{} = orchestrator_uri) do
    with %URI{} = workspace_uri <- workspace_of_orchestrator(orchestrator_uri),
         %URI{} = session_uri <-
           find_session_for_orchestrator(orchestrator_uri, workspace_uri) do
      {:ok, session_uri, workspace_uri}
    else
      _ -> :error
    end
  end

  defp workspace_of_orchestrator(%URI{} = orchestrator_uri) do
    case Ezagent.Capability.workspace_of(orchestrator_uri) do
      %URI{} = ws -> ws
      _ -> nil
    end
  end

  # Enumerate `session`-type snapshot rows in the workspace; return the
  # Session URI whose derived orchestrator URI equals the target.
  defp find_session_for_orchestrator(%URI{} = orchestrator_uri, %URI{} = workspace_uri) do
    target = URI.to_string(orchestrator_uri)

    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
    |> Stream.filter(&(&1.kind_type == "session"))
    |> Stream.map(& &1.uri)
    |> Enum.find_value(fn uri_str ->
      with {:ok, session_uri} <- safe_parse(uri_str),
           %URI{} = derived <-
             safe_derive_orchestrator_uri(session_uri, workspace_uri),
           true <- URI.to_string(derived) == target do
        session_uri
      else
        _ -> nil
      end
    end)
  end

  defp safe_parse(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    _ -> :error
  end

  defp safe_derive_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    Ezagent.Entity.Session.derive_orchestrator_uri(session_uri, workspace_uri)
  rescue
    _ -> nil
  end

  # Load the Session's durable `:chat` slice from its persisted snapshot.
  #
  # T3 (Lifecycle Phase B foundation) — the persisted `:chat` slice may be
  # the two-container shape `%{state: persistent, ...}` once `Behavior.Chat`
  # converts to `use Ezagent.Lifecycle` (the snapshot strips `:transients`,
  # so on disk it is `%{state: persistent}`). We route it through the SAME
  # `Ezagent.Kind.normalize_slice_view/1` chokepoint the live `get_slice/2`
  # read path uses, so this persisted-snapshot consumer reads the flat
  # `owner_uri` / `template_working_copy` regardless of producer migration.
  # A legacy-flat slice passes through unchanged.
  defp load_chat_slice(%URI{} = session_uri) do
    case Ezagent.Ecto.KindSnapshot.get(URI.to_string(session_uri)) do
      %Ezagent.Ecto.KindSnapshot{} = row ->
        case Ezagent.Ecto.KindSnapshot.decode_state(row) do
          {:ok, %{chat: chat_slice}} when is_map(chat_slice) ->
            # Lifecycle migration (SPEC 2026-05-29 §2.3C): the persisted Chat
            # slice is now the two-container shape (transients stripped at
            # persist, so only `:state` survives). The orchestrator reads
            # (`:template_working_copy` / `:owner_uri`) live under `:state`.
            # Route through the canonical T3 chokepoint
            # `Ezagent.Kind.normalize_slice_view/1` (same fn the live
            # `get_slice/2` read path uses) rather than an inline unwrap, so
            # there is one normalization definition; a pre-migration flat
            # snapshot falls through unchanged.
            case Ezagent.Kind.normalize_slice_view(chat_slice) do
              normalized when is_map(normalized) -> {:ok, normalized}
              _ -> :error
            end

          _ ->
            :error
        end

      nil ->
        :error
    end
  end

  # A session HAS an orchestrator iff its durable working copy carries an
  # `:orchestrator_template_uri`. `EzagentDomainChat.create_session/3`'s
  # step-4 materialization sets it for an orchestrator-bearing template;
  # a plain / system session leaves it `nil`. No orchestrator →
  # legitimate fail-closed (the caller maps `:error` →
  # `:orchestrator_not_registered`).
  defp orchestrator_working_copy(chat_slice) do
    wc = Map.get(chat_slice, :template_working_copy, %{})

    case Map.get(wc, :orchestrator_template_uri) do
      %URI{} -> {:ok, wc}
      _ -> :error
    end
  end

  # Recover `parent_template_uri` (the SessionTemplate the session was
  # instantiated from) — the opt `Tools.update_template/1` hard-requires.
  #
  # POST-#110 snapshots persist it durably on the working copy as
  # `:session_template_uri` (written by
  # `EzagentDomainChat.create_session/3`'s step-4
  # `materialize_orchestrator_working_copy/3` — the atomic writer that
  # replaced the deleted Generator `Session.merge_working_copy/6`).
  # That is the canonical source — use it when present.
  #
  # LEGACY snapshots (written before the #110 commit) have NO
  # `:session_template_uri`, and it is GENUINELY UNRECOVERABLE from any
  # durable data those rows carry. SessionTemplates are content-addressed
  # — the Generator's `parent_template_uri` is the full
  # `template://session/<ws>/<name>@<hash>`, and `update_template` /
  # `check_parent_alive` require the EXACT hashed version to re-version
  # the right parent. A legacy Session snapshot records neither the hash
  # nor the parent URI; the Session URI's name segment carries only the
  # bare template NAME (`<owner>-<name>`), never the hash. So we CANNOT
  # reconstruct a usable parent URI for a legacy session.
  #
  # Per `feedback_let_it_crash_no_workarounds`: we do NOT paper over this
  # with a hashless guess (it would fail `check_parent_alive` anyway, or
  # worse, re-version the wrong content). We return `nil`. The 6 other
  # orchestrator tools work fine after restart; ONLY `update_template`
  # fails for a legacy session, and it fails LOUDLY with an explicit
  # `{:missing_opt, :parent_template_uri}` → `:missing_context` MCP error
  # ("Missing orchestrator context: parent_template_uri"). The structural
  # remedy for an affected legacy session is `save_template_as` (which
  # does not require a parent) or a one-time fresh re-spawn that writes
  # the new durable field. This is a clear surfaced limitation, not a
  # silent nil.
  defp recover_parent_template_uri(wc, %URI{} = _session_uri, _owner_uri, %URI{} = _workspace_uri) do
    case Map.get(wc, :session_template_uri) do
      %URI{} = uri -> uri
      _ -> nil
    end
  end

  # Read the orchestrator agent's `:identity` slice caps via the
  # `identity.list_caps` dispatch. The `ctx` runs under
  # `system://orchestrator-tools` (SPEC caps-cleanup-v1 §4.4) — this
  # is TRUSTED INFRASTRUCTURE reading the orchestrator's OWN delegated
  # caps to bind its MCP server, the same privileged-read pattern the
  # Generator's `read_template_content/2` uses. It does NOT grant the
  # orchestrator anything: the loaded caps are exactly what the
  # Generator delegated (§1.4) — the four scope-bounded caps, or fewer
  # if a preflight dropped one. An orchestrator with no delegated caps
  # yields an empty set, and every tool then DENIES (no `admin_caps`
  # fallback — SPEC §2 PR-5 HIGH-1).
  defp load_orchestrator_caps(%URI{} = orchestrator_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(orchestrator_uri)}?action=identity.list_caps")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("orchestrator-tools"),
             caps: Ezagent.SystemPrincipal.caps("system://orchestrator-tools"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{caps: caps}} when is_list(caps) -> MapSet.new(caps)
      _ -> MapSet.new()
    end
  end

  @doc """
  Reload the orchestrator's caps from its `:identity` slice into the
  bound context. Caps are static after Generator boot (§1.4) so this is
  rarely needed — provided for completeness.
  """
  @spec refresh_caps(t()) :: t()
  def refresh_caps(%__MODULE__{orchestrator_uri: uri} = ctx) do
    %{ctx | caps: load_caps(uri)}
  end

  defp load_caps(%URI{} = orchestrator_uri) do
    Ezagent.Identity.list_caps_for(orchestrator_uri)
  rescue
    _ -> MapSet.new()
  end

  defp fetch_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri ->
        {:ok, uri}

      s when is_binary(s) ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue to preserve the `{:error, _}` contract for
        # malformed opts.
        try do
          {:ok, Ezagent.URI.new!(s)}
        rescue
          ArgumentError -> {:error, {:invalid_uri_opt, key, s}}
        end

      nil ->
        {:error, {:missing_opt, key}}

      other ->
        {:error, {:invalid_uri_opt, key, other}}
    end
  end

  # --- tool JSON schemas (MCP tools/list) --------------------------------

  @doc """
  The MCP `tools/list`-shaped descriptor for all 7 orchestrator tools
  (SPEC §2.1 — one schema per tool). The `claude` orchestrator's MCP
  client presents these to the LLM.

  NOTE — caller / cap / session context is NOT in any tool's
  `inputSchema`. It is bound server-side (`%McpServer{}`); the LLM
  supplies only the operation-shaped args.
  """
  @spec tool_schemas() :: [map()]
  def tool_schemas do
    [
      %{
        "name" => "add_managed_member",
        "description" =>
          "Spawn a worker agent from an AgentTemplate and join it to your " <>
            "session as a MEMBER with a stable role_name. The member is " <>
            "reached by rules targeting its role_name (see " <>
            "define_rule_set_rule). Replaces the retired add_agent_slot " <>
            "(a slot was just a member with extra facets).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source_agent_template_uri" => %{
              "type" => "string",
              "description" => "template://agent/<workspace>/<name> to spawn the member from."
            },
            "role_name" => %{
              "type" => "string",
              "description" => "Stable per-session alias for this member (rules/legends target it)."
            },
            "in_session_template" => %{
              "type" => "boolean",
              "description" =>
                "Whether this member is captured in a SessionTemplate snapshot " <>
                  "(true for a persistent team member). Defaults to true."
            }
          },
          "required" => ["source_agent_template_uri", "role_name"]
        }
      },
      %{
        "name" => "remove_member",
        "description" =>
          "Remove a session member by role_name: terminate the worker you " <>
            "spawned and prune routing rules naming it. Idempotent. Reports " <>
            "the rule-set impact (deleted vs repointed rules). Replaces the " <>
            "retired remove_agent_slot.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "role_name" => %{"type" => "string", "description" => "The member role_name to remove."}
          },
          "required" => ["role_name"]
        }
      },
      %{
        "name" => "define_rule_set_rule",
        "description" =>
          "Add a SINGLE-RECEIVER routing rule to a named rule-set: when a " <>
            "message matches the matcher, deliver it to the member named by " <>
            "receiver_role_name, optionally rendered with a prompt template. " <>
            "Rule-sets express multi-agent flows as static {from: X} -> Y " <>
            "rules (NO model-computed baton). Replaces write_matcher.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "matcher_ast" => %{
              "type" => "object",
              "description" =>
                "A routing matcher in JSON form, e.g. " <>
                  ~s({"type":"mention","arg":"传话游戏"} or {"type":"from","arg":"<member-uri>"}.)
            },
            "receiver_role_name" => %{
              "type" => "string",
              "description" => "The member role_name (or concrete URI) the matched message routes to."
            },
            "rule_set" => %{
              "type" => "string",
              "description" => "Name of the rule-set this rule belongs to (the team-flow group)."
            },
            "position" => %{
              "type" => "integer",
              "description" => "Ordinal position of this rule within the rule-set (default 0)."
            },
            "prompt_template_ref" => %{
              "type" => "string",
              "description" =>
                "Optional — name of a prompt template (see define_prompt_template) " <>
                  "rendered into the delivered message."
            }
          },
          "required" => ["matcher_ast", "receiver_role_name", "rule_set"]
        }
      },
      %{
        "name" => "define_prompt_template",
        "description" =>
          "Install a named prompt template on your session. Rules reference " <>
            "it via prompt_template_ref; it is rendered at delivery with " <>
            "variables like {body}/{sender}. Merges into the existing map.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "The prompt template name."},
            "template" => %{
              "type" => "string",
              "description" =>
                "The template string, e.g. " <> ~s("接龙：{body}（by {sender}）". {body} is required.)
            }
          },
          "required" => ["name", "template"]
        }
      },
      %{
        "name" => "define_legend",
        "description" =>
          "Front a rule-set with a @legend handle: a user-facing name that " <>
            "collapses a team (members by role_name) and triggers its " <>
            "rule-set flow. @legend resolves through the legend registry to " <>
            "the rule-set's entry rule.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "legend_name" => %{"type" => "string", "description" => "The @-handle, e.g. 传话游戏."},
            "member_role_names" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Role_names of the team members this legend collapses."
            },
            "bound_rule_set" => %{
              "type" => "string",
              "description" => "The rule-set name @legend triggers."
            },
            "fold" => %{
              "type" => "boolean",
              "description" => "Whether the legend collapses (folds) the member set. Defaults to true."
            }
          },
          "required" => ["legend_name", "member_role_names", "bound_rule_set"]
        }
      },
      %{
        "name" => "update_template",
        "description" =>
          "Snapshot the current session as a NEW VERSION of the parent " <>
            "SessionTemplate it was instantiated from. Persists a real, " <>
            "content-addressed template version.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      },
      %{
        "name" => "save_template_as",
        "description" =>
          "Snapshot the current session as the FIRST VERSION of a NEW " <>
            "SessionTemplate family under the given name.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "new_name" => %{"type" => "string", "description" => "Name for the new template family."}
          },
          "required" => ["new_name"]
        }
      },
      %{
        "name" => "list_templates",
        "description" =>
          "List the AgentTemplates and SessionTemplates visible to you in " <>
            "your workspace. Results are filtered by your capabilities.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name_filter" => %{
              "type" => "string",
              "description" => "Optional substring filter on template names."
            }
          },
          "required" => []
        }
      }
    ]
  end

  @doc "The 7 tool names this MCP server exposes (matches `Tools.tool_names/0`)."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(tool_schemas(), & &1["name"])

  # --- tool dispatch (value form) ----------------------------------------

  @doc """
  Execute an MCP `tools/call` against the bound context.

  `tool` is the tool name (string or atom); `arguments` is the
  JSON-decoded argument map the LLM supplied (string keys). The
  caller / cap / session context comes ENTIRELY from `ctx` — the
  arguments carry only operation-shaped fields.

  Returns an MCP-shaped result map:

  - success — `%{"content" => [%{"type" => "text", "text" => ...}],
    "structuredContent" => <result>}`
  - tool error — `%{"isError" => true, "content" => [...],
    "error" => %{"code" => <atom-string>, "message" => <human text>}}`

  A dispatch `{:error, :unauthorized}` / `{:error, :cross_workspace_denied}`
  / any other `{:error, _}` is mapped to a structured MCP tool error
  (never a silent success, never a raw crash).
  """
  @spec handle_tool_call(t(), String.t() | atom(), map()) :: map()
  def handle_tool_call(%__MODULE__{} = ctx, tool, arguments)
      when is_map(arguments) do
    tool_name = normalize_tool(tool)

    cond do
      tool_name == nil ->
        mcp_error(:unknown_tool, "Unknown tool: #{inspect(tool)}")

      true ->
        result = run_tool(ctx, tool_name, arguments)
        to_mcp_result(tool_name, result)
    end
  end

  def handle_tool_call(%__MODULE__{} = ctx, tool, _arguments) do
    handle_tool_call(ctx, tool, %{})
  end

  defp normalize_tool(tool) when is_atom(tool) do
    if Tools.tool?(tool), do: tool, else: nil
  end

  defp normalize_tool(tool) when is_binary(tool) do
    case Enum.find(Tools.tool_names(), &(Atom.to_string(&1) == tool)) do
      nil -> nil
      atom -> atom
    end
  end

  defp normalize_tool(_), do: nil

  # Run the named tool against the bound context. Each branch reads
  # operation args from `arguments` (the LLM-supplied map) and the
  # caller/cap/session context from `ctx` — the LLM never supplies the
  # latter.
  defp run_tool(%__MODULE__{} = ctx, :add_managed_member, args) do
    with {:ok, tmpl_uri} <- arg_uri(args, "source_agent_template_uri"),
         {:ok, role_name} <- arg_string(args, "role_name") do
      in_session_template = arg_optional_boolean(args, "in_session_template", true)
      Tools.add_managed_member(tmpl_uri, role_name, in_session_template, tool_opts(ctx))
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :remove_member, args) do
    with {:ok, role_name} <- arg_string(args, "role_name") do
      Tools.remove_member(role_name, tool_opts(ctx))
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :define_rule_set_rule, args) do
    with {:ok, matcher} <- arg_matcher(args, "matcher_ast"),
         {:ok, receiver_role} <- arg_string(args, "receiver_role_name"),
         {:ok, rule_set} <- arg_string(args, "rule_set") do
      rule_opts =
        [
          rule_set: rule_set,
          position: arg_optional_integer(args, "position", 0),
          prompt_template_ref: arg_optional_string(args, "prompt_template_ref")
        ] ++ tool_opts(ctx)

      Tools.define_rule_set_rule(matcher, receiver_role, rule_opts)
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :define_prompt_template, args) do
    with {:ok, name} <- arg_string(args, "name"),
         {:ok, template} <- arg_string(args, "template") do
      Tools.define_prompt_template(name, template, tool_opts(ctx))
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :define_legend, args) do
    with {:ok, legend_name} <- arg_string(args, "legend_name"),
         {:ok, member_role_names} <- arg_string_list(args, "member_role_names"),
         {:ok, bound_rule_set} <- arg_string(args, "bound_rule_set") do
      fold = arg_optional_boolean(args, "fold", true)
      Tools.define_legend(legend_name, member_role_names, bound_rule_set, fold, tool_opts(ctx))
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :update_template, _args) do
    Tools.update_template(tool_opts(ctx))
  end

  defp run_tool(%__MODULE__{} = ctx, :save_template_as, args) do
    with {:ok, new_name} <- arg_string(args, "new_name") do
      Tools.save_template_as(new_name, tool_opts(ctx))
    end
  end

  defp run_tool(%__MODULE__{} = ctx, :list_templates, args) do
    Tools.list_templates(arg_optional_string(args, "name_filter"), tool_opts(ctx))
  end

  @doc """
  The orchestrator's caller context every `Tools.*` function consumes:
  `caller` + `caps` + `session_uri` + `workspace_uri` (+ `owner` /
  `parent_template_uri` for the template tools) — all from the bound
  `%McpServer{}`, NEVER from tool args. Public so tests (and the live
  bridge) can drive `Tools.*` against a bound context directly.
  """
  @spec tool_opts(t()) :: keyword()
  def tool_opts(%__MODULE__{} = ctx) do
    [
      caller: ctx.orchestrator_uri,
      caps: ctx.caps,
      session_uri: ctx.session_uri,
      workspace_uri: ctx.workspace_uri,
      owner: ctx.owner_uri,
      parent_template_uri: ctx.parent_template_uri
    ]
  end

  # --- arg extraction ----------------------------------------------------

  defp arg_string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp arg_optional_string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp arg_optional_boolean(args, key, default) do
    case Map.get(args, key) do
      b when is_boolean(b) -> b
      _ -> default
    end
  end

  defp arg_optional_integer(args, key, default) do
    case Map.get(args, key) do
      i when is_integer(i) -> i
      _ -> default
    end
  end

  defp arg_uri(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue to preserve the `{:error, _}` contract for
        # malformed MCP args.
        try do
          {:ok, Ezagent.URI.new!(s)}
        rescue
          ArgumentError -> {:error, {:invalid_arg, key}}
        end

      %URI{} = uri ->
        {:ok, uri}

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  defp arg_string_list(args, key) do
    case Map.get(args, key) do
      list when is_list(list) ->
        {:ok, Enum.map(list, &to_string/1)}

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  # The matcher arg may arrive as a JSON map OR a 2-tuple (test form).
  defp arg_matcher(args, key) do
    case Map.get(args, key) do
      %{} = m -> {:ok, m}
      t when is_tuple(t) -> {:ok, t}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  # --- result mapping ----------------------------------------------------

  defp to_mcp_result(_tool, {:ok, value}) do
    %{
      "content" => [%{"type" => "text", "text" => describe_success(value)}],
      "structuredContent" => stringify(value),
      "isError" => false
    }
  end

  defp to_mcp_result(_tool, {:error, reason}) do
    {code, message} = error_to_mcp(reason)
    mcp_error(code, message)
  end

  # Any non-tuple return (a bare `:ok`, etc.) — treat as success.
  defp to_mcp_result(_tool, other) do
    %{
      "content" => [%{"type" => "text", "text" => describe_success(other)}],
      "structuredContent" => stringify(other),
      "isError" => false
    }
  end

  defp mcp_error(code, message) do
    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => message}],
      "error" => %{"code" => to_string(code), "message" => message}
    }
  end

  # Map a tool / dispatch error reason to a structured MCP tool error.
  # The structured-error message text follows SPEC §2.1's error mapping.
  defp error_to_mcp(:unauthorized),
    do: {:unauthorized, "Not authorized — you lack the capability for this operation."}

  defp error_to_mcp(:cross_workspace_denied),
    do: {:cross_workspace_denied, "Denied — target is outside your workspace."}

  defp error_to_mcp(:parent_template_deleted),
    do:
      {:parent_template_deleted,
       "The parent template is gone — use save_template_as to persist under a new name."}

  # team-routing-unification §3.8 — member/rule-set tool errors.
  defp error_to_mcp({:unknown_rule_receiver, r}),
    do:
      {:unknown_rule_receiver,
       "Rule receiver #{inspect(r)} is neither a current member role_name nor a " <>
         "valid URI — add the managed member (add_managed_member) first."}

  defp error_to_mcp({:source_template_missing_flavor, uri}),
    do:
      {:source_template_missing_flavor,
       "The source AgentTemplate #{URI.to_string(uri)} has no flavor — cannot spawn a member from it."}

  defp error_to_mcp({:role_name_taken, role_name}),
    do:
      {:role_name_taken,
       "role_name #{inspect(role_name)} is already held by another member in this session."}

  defp error_to_mcp({:missing_opt, key}),
    do: {:missing_context, "Missing orchestrator context: #{key}"}

  defp error_to_mcp({:missing_arg, key}),
    do: {:invalid_arguments, "Missing required argument: #{key}"}

  defp error_to_mcp({:invalid_matcher, _}),
    do: {:invalid_matcher, "Invalid matcher — could not parse the routing matcher."}

  defp error_to_mcp(:hash_mismatch),
    do: {:hash_mismatch, "Template content hash mismatch — refusing to persist."}

  defp error_to_mcp(:immutable_version),
    do: {:immutable_version, "That template version already exists with different content."}

  defp error_to_mcp(reason),
    do: {:tool_error, "Operation failed: #{inspect(reason)}"}

  defp describe_success(%URI{} = uri), do: "ok: #{URI.to_string(uri)}"
  defp describe_success(:already_removed), do: "ok: member already removed"
  defp describe_success(map) when is_map(map), do: "ok: #{inspect(stringify(map))}"
  defp describe_success(other), do: "ok: #{inspect(other)}"

  # Make a tool result JSON-serializable for `structuredContent` — URIs
  # become strings; lists/maps recurse.
  defp stringify(%URI{} = uri), do: URI.to_string(uri)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(other), do: other

  # --- GenServer (process form) ------------------------------------------

  @doc """
  Start the orchestrator MCP server as a process bound to one
  orchestrator agent. `opts` are the `new/1` opts plus an optional
  `:name` for registration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Execute a tool call against a running MCP-server process.
  """
  @spec tool_call(GenServer.server(), String.t() | atom(), map()) :: map()
  def tool_call(server, tool, arguments) do
    GenServer.call(server, {:tool_call, tool, arguments})
  end

  @doc "Return the bound context of a running MCP-server process."
  @spec context(GenServer.server()) :: t()
  def context(server), do: GenServer.call(server, :context)

  @impl GenServer
  def init(opts) do
    case new(opts) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:tool_call, tool, arguments}, _from, %__MODULE__{} = ctx) do
    args = if is_map(arguments), do: arguments, else: %{}
    {:reply, handle_tool_call(ctx, tool, args), ctx}
  end

  def handle_call(:context, _from, %__MODULE__{} = ctx) do
    {:reply, ctx, ctx}
  end
end
