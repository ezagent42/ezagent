defmodule Ezagent.Behavior.Template do
  @moduledoc """
  Template Behavior — the dispatchable template-CONTENT Behavior for the
  AgentTemplate + SessionTemplate Kinds (Phase 7 completion SPEC §1.0,
  codex rev-4 HIGH-1+2).

  ## Why this Behavior exists

  rev 3's persistence plan dispatched `identity.update_slice` to persist
  a template version and routed `add_agent_slot` to a bare
  `template.instantiate` callback. Both targeted **non-existent dispatch
  actions** — `Ezagent.Behavior.Identity` exposes only
  `list_caps/has_cap?/grant_cap/revoke_cap` (and its `:identity` slice
  holds CAPS, not template content), and `Ezagent.Kind.Template` is a
  callback-module contract, not a `BehaviorRegistry`-registered action.

  `Ezagent.Behavior.Template` is the fix: a real `@behaviour
  Ezagent.Behavior` carrying the persistent template-CONTENT slice with
  dispatchable `:read` / `:write` / `:instantiate` actions, registered on
  BOTH Template Kinds.

  ## State slice — `:template`

  A NEW slice, separate from `:identity`. Both Template Kinds
  (AgentTemplate / SessionTemplate) carry `Ezagent.Behavior.Identity`
  for the cap policy AND `Ezagent.Behavior.Template` for the content:

  - `:identity` — the cap policy (`default_caps`, owner-grant caps)
  - `:template` — `%{content: map() | nil}` — the template CONTENT

  `init_slice/1` reads `args[:content]` (default `nil` — an unpopulated
  template Kind). The content map is the per-Kind schema:

  - **AgentTemplate `:template` content** — `name`, `description`,
    `flavor`, `working_directory`, `claude_config_dir`, `settings_path`,
    `mcp_config_path`, `api_key_helper`, `default_caps`, `created_by`,
    `created_at`.
  - **SessionTemplate `:template` content** — `name`, `description`,
    `agent_slots`, `orchestrator_template_uri`, `routing_rules`,
    `default_workspace_uri`, `parent_template_uri`, `version_hash`,
    `version_tag`, `created_by`, `created_at`.

  ## Actions — `:read` / `:write` / `:instantiate`

  - **`:read`** (`:call`) — `{:ok, slice, %{content: map | nil}}`.
    Returns the `:template` slice content.
  - **`:write`** (`:call`, args `%{content: map}`) — persists the
    `:template` slice content. Because both Template Kinds are
    `{:snapshot, :on_change}`, a `:write` triggers a `kind_snapshots`
    row write — this is the persistence primitive. The snapshot layer
    upserts by URI, so `:write` is **kind-specific** (codex rev-5
    CRITICAL):
    - **SessionTemplate `:write` is write-once + hash-checked.**
      Recomputes `SessionTemplate.compute_version_hash/1` over `content`
      and requires it to equal the `@<hash>` segment of the Kind's own
      URI — a mismatch → `{:error, :hash_mismatch}`. A `:write` to a
      SessionTemplate whose `:template` slice is already non-empty →
      `{:error, :immutable_version}` UNLESS the new content is logically
      identical (an idempotent retry, which no-ops). A new version is a
      NEW Kind at a NEW `@<hash>` URI — `:write` NEVER edits an existing
      hash in place.
    - **AgentTemplate `:write` is a plain mutable replace** —
      AgentTemplate URIs are versionless (`template://agent/<ws>/<name>`,
      no `@<hash>`); an operator edits the config in place.
  - **`:instantiate`** (`:call`) — runs **inside the Template Kind
    process with the `:template` slice already in hand**. It does NOT
    re-dispatch `:read` to itself (a nested synchronous dispatch to the
    same instance is a self-`GenServer.call` deadlock — codex rev-5
    HIGH-2). For an **AgentTemplate** Kind: resolves the flavor Class
    via `Ezagent.AgentFlavorRegistry.lookup/1` and calls the in-process
    spawn helper `Ezagent.Entity.Agent.spawn_from_template_content/4`
    (§1.6a), which delegates the launch + records lineage + binds
    workspace from the in-hand content. For a **SessionTemplate** Kind:
    returns `{:error, :use_generator}` — SessionTemplate instantiation
    IS the Generator (`Session.spawn_from_template/2`, PR-4); the
    Behavior does not duplicate it.

  ## Relationship to `Ezagent.Kind.Template`

  `Ezagent.Kind.Template` (`template_name/0` + `validate/1` +
  `instantiate/3`) keeps its existing role — the **Template-CLASS**
  contract plugin Template Classes implement (`CcAgent` implements it).
  `Ezagent.Behavior.Template` is a different thing: a **Behavior on the
  Template KIND** that holds + serves the persistent content slice and
  routes dispatchable actions. The `:instantiate` action *delegates to*
  a `Ezagent.Kind.Template` Class — it does not replace it.
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.Entity.{AgentTemplate, SessionTemplate}

  @impl Ezagent.Behavior
  def actions, do: [:read, :write, :instantiate]

  @impl Ezagent.Behavior
  def state_slice, do: :template

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{content: Map.get(args, :content)}
  end

  # --- :read -------------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:read, slice, _args, _ctx) do
    {:ok, slice, %{content: Map.get(slice, :content)}}
  end

  # --- :write ------------------------------------------------------------

  def invoke(:write, slice, %{content: content}, ctx) when is_map(content) do
    case Map.get(ctx, :kind_module) do
      SessionTemplate ->
        write_session_template(slice, content, ctx)

      AgentTemplate ->
        # AgentTemplate URIs are versionless — plain mutable replace.
        {:ok, %{slice | content: content}, %{content: content}}

      other ->
        {:error, {:template_write_unsupported_for_kind, other}}
    end
  end

  # --- :instantiate ------------------------------------------------------

  # codex rev-5 HIGH-2 — `:instantiate` runs IN-PROCESS with the slice
  # already in hand. It NEVER dispatches `:read` back to its own Kind
  # process (a self-`GenServer.call` deadlock).
  def invoke(:instantiate, slice, args, ctx) do
    case Map.get(ctx, :kind_module) do
      AgentTemplate ->
        instantiate_agent_template(slice, args, ctx)

      SessionTemplate ->
        # SessionTemplate instantiation IS the Generator
        # (`Session.spawn_from_template/2`, PR-4). The Behavior does
        # not duplicate it.
        {:error, :use_generator}

      other ->
        {:error, {:template_instantiate_unsupported_for_kind, other}}
    end
  end

  # --- interface ---------------------------------------------------------

  @impl Ezagent.Behavior
  def interface do
    %{
      read: %{
        description: "Read the template's content slice",
        args: %{},
        returns: %{content: :map},
        modes: [:call]
      },
      write: %{
        description:
          "Persist the template's content slice (SessionTemplate write-once + " <>
            "hash-checked; AgentTemplate mutable replace)",
        args: %{content: :map},
        returns: %{content: :map},
        modes: [:call]
      },
      instantiate: %{
        description:
          "Instantiate the template — AgentTemplate spawns a worker via its " <>
            "flavor Class; SessionTemplate returns {:error, :use_generator}",
        args: %{
          instance_name: {:option, :string},
          workspace_uri: {:option, :uri},
          spawned_by: {:option, :uri}
        },
        returns: %{workers: {:list, :uri}},
        modes: [:call]
      }
    }
  end

  # --- internals ---------------------------------------------------------

  # SessionTemplate `:write` — write-once + hash-checked (codex rev-5
  # CRITICAL). A SessionTemplate version is content-addressed: the
  # `@<hash>` segment of its URI MUST equal the recomputed hash of the
  # content being written, and an already-populated slice may not be
  # divergently overwritten.
  defp write_session_template(slice, content, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    with {:ok, uri_hash} <- uri_hash_segment(self_uri),
         :ok <- check_hash_matches(content, uri_hash),
         :ok <- check_immutable(Map.get(slice, :content), content) do
      {:ok, %{slice | content: content}, %{content: content}}
    end
  end

  # The hash check: recompute over `content`, require == the URI's
  # `@<hash>` segment. URI ↔ content must agree.
  defp check_hash_matches(content, uri_hash) do
    if SessionTemplate.compute_version_hash(content) == uri_hash do
      :ok
    else
      {:error, :hash_mismatch}
    end
  end

  # The immutable-version check: a `:write` to an already-non-empty
  # `:template` slice is rejected UNLESS the new content is logically
  # identical (an idempotent retry, which no-ops as success).
  defp check_immutable(nil, _new), do: :ok
  defp check_immutable(same, same), do: :ok
  defp check_immutable(_existing, _new), do: {:error, :immutable_version}

  # Extract the `@<hash>` segment from a SessionTemplate URI's name
  # path segment: `template://session/<ws>/<name>@<hash>`.
  defp uri_hash_segment(%URI{path: "/" <> rest}) when is_binary(rest) do
    case String.split(rest, "@", parts: 2) do
      [_name, hash] when hash != "" -> {:ok, hash}
      _ -> {:error, :missing_version_hash_in_uri}
    end
  end

  defp uri_hash_segment(_), do: {:error, :missing_version_hash_in_uri}

  # AgentTemplate `:instantiate` — resolve flavor → Class, build the
  # Class data map, hand off to the in-process spawn helper (§1.6a). NO
  # `:read` self-dispatch.
  defp instantiate_agent_template(slice, args, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    case Map.get(slice, :content) do
      content when is_map(content) ->
        with {:ok, instance_uri} <- resolve_instance_uri(content, args, self_uri, ctx),
             {:ok, workspace_uri} <- resolve_workspace_uri(content, args, self_uri),
             spawned_by <- resolve_spawned_by(args, ctx),
             {:ok, workers} <-
               Ezagent.Entity.Agent.spawn_from_template_content(
                 content,
                 instance_uri,
                 spawned_by,
                 workspace_uri
               ) do
          {:ok, slice, %{workers: workers}}
        end

      _ ->
        {:error, :template_not_populated}
    end
  end

  # The per-instance agent URI. The caller (Generator / add_agent_slot)
  # supplies `instance_name`; the URI is built in the resolved
  # workspace, flavor-prefixed per SPEC §1.2.
  defp resolve_instance_uri(content, args, self_uri, ctx) do
    with {:ok, workspace_uri} <- resolve_workspace_uri(content, args, self_uri) do
      flavor = Map.get(content, :flavor) || Map.get(content, "flavor")
      workspace_name = workspace_uri.host || "default"

      case Map.get(args, :instance_name) do
        name when is_binary(name) and name != "" and is_binary(flavor) and flavor != "" ->
          {:ok, URI.new!("entity://agent/#{workspace_name}/#{flavor}_#{name}")}

        name when is_binary(name) and name != "" ->
          # No flavor in the content — let the helper error on the
          # flavor lookup instead of constructing a bad URI.
          {:ok, URI.new!("entity://agent/#{workspace_name}/#{name}")}

        _ ->
          {:error, {:missing_instance_name, kind: Map.get(ctx, :kind_module)}}
      end
    end
  end

  # The workspace URI. Prefer the explicit arg; otherwise derive from
  # the AgentTemplate's own URI workspace segment.
  defp resolve_workspace_uri(_content, %{workspace_uri: %URI{} = ws}, _self_uri), do: {:ok, ws}

  defp resolve_workspace_uri(_content, _args, %URI{} = self_uri) do
    case Ezagent.Capability.workspace_of(self_uri) do
      %URI{} = ws -> {:ok, ws}
      :any -> {:error, :cannot_derive_workspace}
    end
  end

  defp resolve_workspace_uri(_content, _args, _self_uri), do: {:error, :cannot_derive_workspace}

  # The principal authorizing the spawn (recorded in AgentLineage).
  # Prefer the explicit arg; fall back to the dispatch caller.
  defp resolve_spawned_by(%{spawned_by: %URI{} = uri}, _ctx), do: uri
  defp resolve_spawned_by(_args, ctx), do: Map.get(ctx, :caller)
end
