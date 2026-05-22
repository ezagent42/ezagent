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

  @doc """
  Persist a SessionTemplate version (Phase 7 completion SPEC §1.7 (a)).

  This is the persistence helper that stands on the Kind/`kind_snapshots`
  model — a SessionTemplate version IS a Kind instance, there is no
  separate "SessionTemplate row" table. Given the template content map
  + the workspace, `persist_version/2`:

  1. computes the content hash via `compute_version_hash/1` — this
     content-addresses the version (identical content ⇒ identical
     hash ⇒ identical URI);
  2. builds the version URI `template://session/<ws>/<name>@<hash>`
     via `build_uri/3`;
  3. **spawns the SessionTemplate Kind** at that URI through
     `Ezagent.SpawnRegistry.spawn/1` (the `template` scheme spawn fn
     routes to `Ezagent.Kind.spawn(SessionTemplate, …)`);
  4. dispatches `Ezagent.Behavior.Template` `:write` (`?action=template.write`)
     to populate the Kind's `:template` content slice. Because
     SessionTemplate is `{:snapshot, :on_change}`, that slice mutation
     writes a `kind_snapshots` row keyed by the hash URI — the
     persistence is the snapshot.

  The `:write` action (PR-1) is the integrity guard: it is write-once
  + hash-checked. It recomputes the hash over `content` and requires it
  to equal the URI's `@<hash>` segment — `persist_version/2` builds the
  URI from the same hash, so a correctly-formed call always passes; a
  caller that hands content whose hash disagrees with a pre-built URI
  is rejected with `{:error, :hash_mismatch}`.

  ## Idempotent on a duplicate hash

  Persisting the SAME content twice resolves to the SAME hash ⇒ the
  SAME URI. The second call finds the Kind already alive
  (`SpawnRegistry.spawn/1` → `{:error, {:already_started, pid}}`) and
  re-dispatches `:write` with identical content — the `:write` action's
  identical-retry no-op (`check_immutable/2` `same, same`) returns
  `{:ok, …}`. Both calls return `{:ok, uri}`; exactly one
  `kind_snapshots` row exists; no error is raised. This is the
  content-addressing idempotency convention of SPEC §1.7 (a).

  ## Caller context

  `persist_version/2` dispatches `:write` with the bootstrap principal's
  authority (`Ezagent.Entity.User.admin_uri/0` + `admin_caps/0`) — the
  same system-internal convention `Ezagent.Template.GenericSession` and
  `Ezagent.Entity.Session.spawn_from_template/2` use for in-process
  orchestration dispatch. The WHO-may-save authorization is a separate
  concern: PR-5's `update_template` / `save_template_as` tools run the
  owner-cap preflight (§1.4) at the tool boundary BEFORE calling this
  helper. The content-hash write-once guard inside `:write` is the
  version-integrity check.

  ## Returns

  - `{:ok, uri}` — the version was persisted (or already existed with
    identical content); `uri` is the `template://session/...@<hash>`
    URI of the version.
  - `{:error, reason}` — the spawn failed, or the `:write` dispatch
    failed (e.g. `:hash_mismatch` for caller-supplied content that
    doesn't agree with its hash).
  """
  @spec persist_version(map(), URI.t() | String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def persist_version(content, workspace) when is_map(content) do
    name = Map.get(content, :name) || Map.get(content, "name")
    workspace_segment = workspace_segment(workspace)

    cond do
      not (is_binary(name) and name != "") ->
        {:error, :missing_template_name}

      is_nil(workspace_segment) ->
        {:error, :invalid_workspace}

      true ->
        hash = compute_version_hash(content)
        uri = build_uri(name, hash, workspace: workspace_segment)

        with {:ok, _pid} <- ensure_kind_alive(uri),
             {:ok, _result} <- dispatch_write(uri, content) do
          {:ok, uri}
        end
    end
  end

  # Spawn the SessionTemplate Kind at the hash URI. A duplicate-hash
  # persist finds the Kind already alive — `{:already_started, pid}` is
  # idempotency, treated as success (SPEC §1.7 (a)).
  defp ensure_kind_alive(uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  # Dispatch `Ezagent.Behavior.Template` `:write` to populate the
  # `:template` slice — the `{:snapshot, :on_change}` mutation writes
  # the `kind_snapshots` row. An identical-content retry no-ops as
  # `{:ok, …}` (the write-once Kind is not corrupted).
  defp dispatch_write(uri, content) do
    target = URI.parse("#{URI.to_string(uri)}?action=template.write")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{content: content},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.Entity.User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # The workspace path segment (no scheme prefix) for `build_uri/3`.
  defp workspace_segment(%URI{scheme: "workspace", host: host})
       when is_binary(host) and host != "",
       do: host

  defp workspace_segment("workspace://" <> rest) when rest != "", do: rest

  defp workspace_segment(name) when is_binary(name) and name != "" do
    # Bare workspace name (no scheme) — accept it directly.
    if String.contains?(name, "/"), do: nil, else: name
  end

  defp workspace_segment(_), do: nil
end
