defmodule EzagentPluginKb.Application do
  @moduledoc """
  KB plugin OTP application — the `Ezagent.Plugin` contract module
  (retrieval-first KB, SPEC rev 3).

  **kb-as-role.** A KB = one **agent** (role `kb` × flavor `native` on the
  unified `Entity.Agent`), mirroring kanban-as-role. The KB is NOT a new Kind,
  NOT a new domain, NOT in ezagent's Postgres. Its corpus is a SEPARATE,
  portable per-KB sqlite file (`EzagentPluginKb.Store`) addressed via
  `resource://<ws>/kb-store/<agent>`. ezagent's own DB stays Postgres; the only
  new dep (`exqlite`) opens ONLY the isolated KB files.

  Pure plugin (path A): this module declares `roles/0` (the `kb` recipe) and
  `resource_types/0` (the store-file + source-doc FsResolver types); the
  framework's `Ezagent.Plugin.boot/1` registers them. The author never touches a
  `*Registry`. The `native` flavor (a separate plugin) supplies the host Kind +
  the fail-closed CapMint policy that grants the recipe's `requested_caps`.

  ## How it comes alive

  Addressed via `entity://<ws>/agent/<id>` (the agent URI). `roles/0` registers
  the `kb` recipe at boot; create goes the RF-5a role-create path
  (`Workspace.create_agent` flavor `native` × role `kb`); `Behavior.Kb` loads
  per-instance on the generic `Entity.Agent` host via RF-1 (no host-Kind
  declaration). Dispatch to a dormant kb-agent rehydrates it from snapshot;
  `Behavior.Kb.activate/2` re-opens the sqlite file (the corpus survives with no
  in-memory rebuild — sqlite IS the disk).
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Resource.FsResolver

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "kb",
      name: "Knowledge Base",
      description:
        "Retrieval-first knowledge base — role `kb` × flavor `native`, a " <>
          "separate portable sqlite FTS5 store per KB.",
      version: "0.1.0"
    }
  end

  @doc """
  The `kb` role recipe (also the recipe-parity gate's subject).

  Public so the role test asserts the exact recipe without re-deriving the
  action list (single source of truth = `Ezagent.ActionSet.Kb`).

    * `behaviors: [Ezagent.ActionSet.Kb]` — the sqlite/FTS5 state half
      (actions `:query` + `:ingest`).
    * `requested_caps` = one `%{behavior:, action:}` cap-template per action —
      NOT a bare atom (`Recipe.new/1` rejects non-maps), NOT carrying a `kind`
      axis (kind is materialization, injected by CapMint per flavor = `:agent`).
      The native CapMint policy grants exactly these (fail-closed, RF-8).
    * `passive: true` — a passive DATA actor (RF-6 three gates): not
      @-mentionable, not `:join`-able, receives no ambient chat — reachable only
      via `kb.<action>` dispatch + the MCP tool.
  """
  @spec kb_recipe() :: map()
  def kb_recipe do
    %{
      name: "kb",
      passive: true,
      behaviors: [Ezagent.ActionSet.Kb],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.Kb, action: :query},
        %{behavior: Ezagent.ActionSet.Kb, action: :ingest}
      ]
    }
  end

  @impl Ezagent.Plugin
  def roles, do: [kb_recipe()]

  @doc "Session-Config operations contributed by the KB plugin."
  def session_config_operations do
    [
      %{
        name: "kb_query",
        description:
          "Retrieve the top-k most relevant chunks from a knowledge-base agent " <>
            "(a `kb`-role agent in your workspace). Returns ranked chunks with " <>
            "provenance (source_uri, chunk_id, score). Use this to ground an " <>
            "answer in indexed documents (keyword/FTS retrieval).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "kb_agent" => %{
              "type" => "string",
              "description" => "Name of the kb-agent in your workspace to query."
            },
            "query" => %{"type" => "string", "description" => "The search query (free text)."},
            "k" => %{
              "type" => "integer",
              "description" => "Max number of chunks to return (default 5)."
            }
          },
          "required" => ["kb_agent", "query"]
        },
        target_scope: :workspace,
        admission_gate: :operation_caps,
        route:
          {:agent_action,
           %{
             agent_arg: "kb_agent",
             behavior: :kb,
             cap_behavior: Ezagent.ActionSet.Kb,
             action: :query,
             args: [query: "query", k: {"k", 5}]
           }}
      },
      %{
        name: "kb_ingest",
        description:
          "Ingest one source document into a knowledge-base agent (a `kb`-role " <>
            "agent in your workspace). The source is referenced by a resource " <>
            "URI in the `resource` scheme; re-ingesting the same source replaces " <>
            "its chunks. Requires the kb.ingest capability (distinct from kb.query).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "kb_agent" => %{
              "type" => "string",
              "description" => "Name of the kb-agent in your workspace to ingest into."
            },
            "source_uri" => %{
              "type" => "string",
              "description" =>
                "A resource-scheme URI of the form " <>
                  "resource:[//]<ws>/kb-source/<name> pointing at the document to ingest."
            }
          },
          "required" => ["kb_agent", "source_uri"]
        },
        target_scope: :workspace,
        admission_gate: :operation_caps,
        route:
          {:agent_action,
           %{
             agent_arg: "kb_agent",
             behavior: :kb,
             cap_behavior: Ezagent.ActionSet.Kb,
             action: :ingest,
             args: [source_uri: "source_uri"]
           }}
      }
    ]
  end

  @doc """
  Plugin-owned `resource://` types (SPEC §4.2 / §4.4), registered at boot by
  `Ezagent.Plugin.boot/1` via `FsResolver.Registry.register_all/1`.

    * `kb-store` (backend `kb-stores`) — the per-KB sqlite file's per-agent
      DIRECTORY: `resource://<ws>/kb-store/<agent>` → `<Home>/kb-stores/<ws>/
      <agent>/`; `Behavior.Kb` appends `kb.sqlite`. The store URI is derived
      from the kb-agent's OWN identity (never caller input) — store-path
      confinement (SPEC §8.5).
    * `kb-source` (backend `kb-sources`) — source documents read at ingest:
      `resource://<ws>/kb-source/<name>` → `<Home>/kb-sources/<ws>/<name>`.

  Both authorities enforce R-3 workspace isolation: a URI's `<ws>` must equal
  the caller's authenticated scope workspace — a foreign-workspace URI is
  rejected (SPEC §8.4 source authority; cross-tenant access structurally
  impossible).
  """
  @impl Ezagent.Plugin
  def resource_types do
    [
      {"kb-store", %{backend_component: "kb-stores", authority: &__MODULE__.kb_authority/2}},
      {"kb-source", %{backend_component: "kb-sources", authority: &__MODULE__.kb_authority/2}}
    ]
  end

  @doc """
  R-3 workspace-isolation authority shared by both KB types: the URI's `<ws>`
  segment must equal the caller's authenticated scope workspace (scope comes
  from the authenticated context, NEVER from the URI).

  Delegates to `FsResolver.config_dir_authority/2` — the canonical, reviewed
  workspace-segment-match authority (it asserts `uri.<ws> == scope.workspace`,
  the exact R-3 check KB needs). Reusing it (rather than re-deriving the
  normalize/compare logic) keeps a single source of truth for the isolation
  rule and avoids a forked copy.
  """
  @spec kb_authority(URI.t(), FsResolver.scope()) :: :ok | {:error, term()}
  def kb_authority(%URI{} = uri, %{workspace: _} = scope) do
    FsResolver.config_dir_authority(uri, scope)
  end

  @impl Ezagent.Plugin
  def config_surface, do: %{kind: :route, path: "/plugins/kb", label: "Knowledge Base"}

  @impl Ezagent.Plugin
  def children, do: []
end
