defmodule Ezagent.Entity.SessionTemplate do
  @moduledoc """
  SessionTemplate Kind — what a team looks like (Phase 7 PR 38).

  Per SPEC D7-2 + D7-7 + D7-10. A SessionTemplate is the
  **production unit of multi-agent orchestration** — a named,
  versioned, forkable configuration describing:

  - which agent slots compose the team
  - which AgentTemplate (PR 37) each slot is instantiated from
  - what routing rules wire the team together (mention routing,
    workspace scope)
  - which orchestrator agent is bundled with the session
  - what workspace newly-instantiated sessions land in
  - lineage back to a parent template (for fork tracking)

  ## URI shape (D7-10 git-style versioning, SPEC v3 §3.6 PR-7)

  `template://session/<workspace>/<name>@<version_hash>` where
  `version_hash` is **SHA-256 over the slice content** (canonical
  encoding, excluding timestamps + created_by). Two rows with
  identical config produce identical hashes — content-addressable.
  The hash is **immutable per row**. `orchestrator.update_template()`
  produces a new row with a new hash.

  PR-7 added the workspace segment so SessionTemplate URIs follow
  the same unified 3-segment shape as every other per-tenant URI.

  Tags (`v1.0`, `stable`, etc.) live in a separate `template_tags`
  registry mapping `(name, tag) → version_hash`. Tags are
  **mutable** — they can be re-pointed at any existing hash for
  the same name. Like git: branches/tags move, commits don't.

  ## Slice schema (per SPEC v3 §SessionTemplate)

      %{
        # metadata
        name:                       String.t(),
        description:                String.t(),

        # team composition
        agent_slots:                [{slot_name :: String.t(),
                                     template_uri :: URI.t()}],
        orchestrator_template_uri:  URI.t(),
        routing_rules:              [{matcher_ast :: term(),
                                      [receiver_slot_name :: String.t()]}],
        default_workspace_uri:      URI.t(),

        # lineage (D7-7 fork model)
        parent_template_uri:        URI.t() | nil,

        # versioning (D7-10)
        version_hash:               String.t(),
        version_tag:                String.t() | nil,

        # provenance
        created_at:                 DateTime.t(),
        created_by:                 URI.t()
      }

  ## Persistence

  `{:snapshot, :on_change}` — SessionTemplates are durable
  configuration; orchestrators need them surviving phx restart so
  `list_templates` returns the catalog regardless of when phx
  started.

  ## Fork vs update vs save_template_as (orchestrator-facing)

  Three operations write SessionTemplate rows; clear separation
  matters because they're frequently confused:

  - **`update_template()`** (orchestrator tool, PR 46): produces a
    NEW VERSION of the **current parent template**. New `version_hash`
    row inserted; older sessions on prior hashes are unaffected.
    Requires `template:write` cap on the parent's name.
  - **`save_template_as(new_name)`** (orchestrator tool, PR 46):
    creates the FIRST VERSION of a NEW template with
    `parent_template_uri = current_parent_hash_uri`. Requires
    template-creation cap (default-granted to most users).
  - **`fork(parent_uri@hash, new_name)`** (registry operation, NOT
    an orchestrator tool — see Decision #141): cold-fork from any
    template hash; the orchestrator inside a running session uses
    `save_template_as` for its in-session equivalent. Fork is a
    SessionTemplate registry verb invoked by Generator / Session
    creation paths.

  Fork unit = configuration only. Message history does NOT fork
  (D7-7).

  ## Generator (Ezagent.Entity.Session.spawn_from_template/2 — PR 41)

  The program that instantiates a SessionTemplate into a running
  Session: reads the SessionTemplate by URI → fresh session URI →
  resolves agent_slots' template URIs → spawns orchestrator agent
  from `orchestrator_template_uri` → spawns each worker agent from
  its AgentTemplate → installs routing rules with
  `workspace_uri = default_workspace_uri` → initializes Session's
  `template_working_copy` slice (PR 44).
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :session_template

  # Phase 7 completion PR-1 (SPEC §1.0): SessionTemplate carries TWO
  # slices — `:identity` (the cap policy) and `:template` (the
  # versioned, content-addressed template CONTENT, served via
  # `Ezagent.Behavior.Template`). SessionTemplate `:write` is
  # write-once + hash-checked (codex rev-5 CRITICAL).
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Identity, Ezagent.Behavior.Template]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): SessionTemplate Kinds live under
  # the chat domain's SessionTemplateSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.SessionTemplateSupervisor

  @doc """
  Compute the deterministic version hash for a slice content map.

  Excludes `created_at` + `created_by` from the hash input so two
  rows with the same logical config produce the same hash regardless
  of who/when they were saved. Uses
  `:erlang.term_to_binary(slice, [:deterministic])` for
  cross-BEAM-run consistency (D7-10).

  Returns a 64-char lowercase hex string (SHA-256 hex digest).
  """
  @spec compute_version_hash(map()) :: String.t()
  def compute_version_hash(slice_content) when is_map(slice_content) do
    canonical =
      slice_content
      |> Map.drop([:created_at, :created_by, :version_hash, :version_tag])
      |> :erlang.term_to_binary([:deterministic])

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Build the URI for a SessionTemplate given name + version hash.

  SPEC v3 §3.6 (Phase 9 PR-7) — defaults the workspace segment to
  `default`. Callers needing a different workspace can pass
  `workspace:` (string, no scheme prefix).
  """
  @spec build_uri(String.t(), String.t(), keyword()) :: URI.t()
  def build_uri(name, version_hash, opts \\ [])
      when is_binary(name) and is_binary(version_hash) do
    workspace = Keyword.get(opts, :workspace, "default")
    URI.new!("template://session/#{workspace}/#{name}@#{version_hash}")
  end
end
