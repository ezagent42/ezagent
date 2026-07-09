defmodule EzagentDomainInstanceMessage.UriQueryResolvers do
  @moduledoc """
  Domain-owned resolvers for `Ezagent.UriQuery`.

  `Ezagent.UriQuery` lives in core and cannot depend on domain storage. This
  module registers the instance-message attributes whose source of truth is the
  live/durable Kind state owned by this domain.
  """

  alias Ezagent.ActionSet.Session

  @doc "Register the instance-message UriQuery resolvers."
  @spec register() :: :ok | {:error, term()}
  def register do
    with :ok <- Ezagent.UriQuery.register(:flavor, &__MODULE__.resolve_flavor/1),
         :ok <- Ezagent.UriQuery.register(:passive, &__MODULE__.resolve_passive/1),
         :ok <- Ezagent.UriQuery.register(:recipe, &__MODULE__.resolve_recipe/1),
         :ok <- Ezagent.UriQuery.register(:orchestrator, &__MODULE__.resolve_orchestrator/1),
         :ok <- Ezagent.UriQuery.register(:member_by_role, &__MODULE__.resolve_member_by_role/1),
         :ok <-
           Ezagent.UriQuery.register(
             :user_default_credential_source,
             &__MODULE__.resolve_user_default_source/1
           ),
         :ok <-
           Ezagent.UriQuery.register(
             :workspace_shared_credential_source,
             &__MODULE__.resolve_workspace_shared_source/1
           ),
         :ok <- Ezagent.UriQuery.register(:config_dir, &__MODULE__.resolve_config_dir/1),
         :ok <-
           Ezagent.UriQuery.register(:session_template, &__MODULE__.resolve_session_template/1) do
      :ok
    end
  end

  @doc false
  # #17 cascade PR-0 (spec §5.2) — resolve a user's default credential source pointer.
  # Arg is a `{owner, ws, flavor}` tuple (UriQuery's 1-arg resolver shape).
  @spec resolve_user_default_source(term()) :: Ezagent.UriQuery.result()
  def resolve_user_default_source({owner, ws, flavor})
      when is_binary(owner) and is_binary(ws) and is_binary(flavor) do
    case Ezagent.Credential.UserDefaultSource.resolve(owner, ws, flavor) do
      nil -> :none
      source -> {:ok, source}
    end
  end

  def resolve_user_default_source(_), do: :none

  @doc false
  # #17 cascade PR-3 — resolve a workspace-shared service-account source pointer.
  # Arg is `{workspace_uri, flavor}` because shared credentials are flavor-specific.
  @spec resolve_workspace_shared_source(term()) :: Ezagent.UriQuery.result()
  def resolve_workspace_shared_source({%URI{} = workspace_uri, flavor})
      when is_binary(flavor) do
    case Ezagent.Credential.WorkspaceSharedSource.resolve(URI.to_string(workspace_uri), flavor) do
      nil -> :none
      source -> {:ok, Ezagent.URI.new!(source)}
    end
  end

  def resolve_workspace_shared_source({workspace_uri, flavor})
      when is_binary(workspace_uri) and is_binary(flavor) do
    case Ezagent.Credential.WorkspaceSharedSource.resolve(workspace_uri, flavor) do
      nil -> :none
      source -> {:ok, Ezagent.URI.new!(source)}
    end
  end

  def resolve_workspace_shared_source(_), do: :none

  @doc false
  @spec resolve_config_dir(term()) :: Ezagent.UriQuery.result()
  def resolve_config_dir(%URI{scheme: "template"} = template_uri) do
    with {:ok, template_slice} <- kind_slice_with_snapshot(template_uri, :template),
         content when is_map(content) <- Map.get(template_slice, :content),
         dir when is_binary(dir) and dir != "" <- content_field(content, :config_dir) do
      {:ok, dir}
    else
      nil -> :none
      :none -> :none
      {:error, _} = err -> err
      _ -> :none
    end
  end

  def resolve_config_dir(%URI{scheme: "entity"} = agent_uri) do
    with {:ok, sandbox_slice} <- kind_slice_with_snapshot(agent_uri, :sandbox),
         dir when is_binary(dir) and dir != "" <- Map.get(sandbox_slice, :config_dir_path) do
      {:ok, dir}
    else
      nil -> :none
      :none -> :none
      {:error, _} = err -> err
      _ -> :none
    end
  end

  # #607 — a `resource://<ws>/socialware-config-object/<b64 object_id>` layer URI
  # names an IMMUTABLE self-evolve config OBJECT owned by the socialware domain.
  # `:config_dir` has one owner (this module), so delegate the projection to
  # socialware's own `:socialware_config_dir` resolver via the runtime UriQuery
  # table — no compile-time dependency on socialware (which depends on THIS app),
  # so no cycle.
  #
  # Resource-unification P1 (codex CRITICAL): a *bare* `resource://` URI carries
  # no separate authenticated subject, so deriving a scope from the URL itself
  # would be tautological (a forged `resource://victim/cc-agents/x` would resolve
  # under `victim`). Therefore the bare clause splits by `<type>`:
  #
  #   * `socialware-config-object` — SELF-authorizing: socialware re-loads the
  #     immutable object and compares its stored `workspace_uri`, so a bare URI is
  #     safe. Delegate to `:socialware_config_dir` exactly as before (unchanged).
  #   * config-dir types (the registered `<ns>-agents` family) — NOT
  #     self-authorizing. A bare URI lacks an authenticated scope → REJECT
  #     (`:config_dir_resource_requires_scope`). There is NO scope-from-URI
  #     fallback. The only legitimate config-dir caller is
  #     `Ezagent.Sandbox.ConfigDir.path/2` (P1.3), which constructs the URI from
  #     the authenticated agent and resolves the FsResolver DIRECTLY — config-dir
  #     `resource://` URIs do not flow through `:config_dir` as bare URIs.
  #   * ANY OTHER resource type — not this attribute's concern → `:none`. The
  #     credential cascade (`CascadeRuntime.layer_dirs/1`,
  #     `Agent.default_layer_dir_for/1`) treats `:none` as "skip this layer" but
  #     `{:error, _}` as a FATAL cascade abort, so a non-config-dir resource layer
  #     (e.g. a future `resource://<ws>/uploads/<f>`) MUST fall through to `:none`
  #     here — exactly as pre-P1, when the socialware resolver returned `:none` for
  #     every type it did not own (codex P1 round-5 HIGH: do not regress unrelated
  #     resource layers into a hard cascade failure).
  def resolve_config_dir(%URI{scheme: "resource"} = resource_uri) do
    case Ezagent.URI.type(resource_uri) do
      {:ok, "socialware-config-object"} ->
        Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)

      {:ok, type} ->
        if Ezagent.Resource.FsResolver.config_dir_type?(type) do
          {:error, :config_dir_resource_requires_scope}
        else
          :none
        end

      :error ->
        :none
    end
  end

  # Scoped payload — config-dir resource types resolved with an EXTERNAL
  # authenticated `scope` (Resource-unification P1, SPEC §5.1). The
  # `FsResolver.authority/2` is meaningful only when `scope.workspace` is
  # independently authenticated; this is the threaded-scope entry point. A
  # `:none` (not an FsResolver-owned type) falls back to the self-authorizing
  # socialware resolver; `{:ok, _}` / `{:error, _}` are returned verbatim
  # (fail loud, never swallowed).
  def resolve_config_dir({%URI{scheme: "resource"} = resource_uri, %{workspace: _} = scope}) do
    case Ezagent.Resource.FsResolver.resolve(resource_uri, scope) do
      :none -> Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)
      other -> other
    end
  end

  def resolve_config_dir(_), do: :none

  @doc false
  @spec resolve_flavor(term()) :: Ezagent.UriQuery.result()
  def resolve_flavor(%URI{} = agent_uri) do
    case Ezagent.AgentFlavorAttributes.get(agent_uri) do
      {:ok, _flavor} = ok ->
        ok

      :none ->
        case resolve_flavor_from_kind(agent_uri) do
          :none -> Ezagent.AgentFlavorResolver.flavor_from_durable_snapshot(agent_uri)
          other -> other
        end
    end
  end

  def resolve_flavor(_), do: :none

  @doc false
  # RF-6/RF-5a: resolve whether `agent_uri` is a PASSIVE (non-principal) data
  # actor — never parsed from the URI. Always `{:ok, boolean}` (never `:none`):
  # the routing/`:join`/mention gates need a definite principal/passive verdict,
  # and "unknown ⇒ principal" (false) is the safe-by-default for legitimate
  # agents.
  #
  # RESTART-SAFE LAYERING (RF-5a — the RF-6 fail-open fix): ETS fast path →
  # durable SNAPSHOT. Two layers, NOT three:
  #
  #   1. `AgentPassiveAttributes.fetch/1` — the volatile ETS fast path. A stored
  #      entry (`{:ok, bool}`) is authoritative. ONLY an ABSENT entry (`:none`)
  #      falls through — a bare `passive?/1 == false` would shadow the durable
  #      layer and reintroduce the cold-restart fail-open RF-6 flagged. The
  #      create step primes this at spawn, so the steady-state path never touches
  #      the snapshot.
  #   2. durable SNAPSHOT `:sandbox` slice `:passive` — after a cold restart the
  #      ETS table is empty, so the passive verdict is recovered from the
  #      persisted snapshot. THIS keeps a passive data-actor from reverting to a
  #      chat principal across a restart.
  #
  # NO live `Kind.get_slice` layer (unlike `resolve_flavor`): `:passive` is
  # IMMUTABLE after create (set once from the recipe), so the snapshot is always
  # current — a live slice read would add nothing. Critically, `resolve_passive`
  # runs on the SESSION `:join` / mention / routing hot path (gating a member
  # being added), where a synchronous cross-Kind `get_slice` to the joining
  # member could deadlock or stall; the snapshot read is a pure DB lookup that
  # never re-enters a Kind. A missing snapshot or non-boolean field → `false`
  # (principal — fail-closed-to-principal, the regression guarantee).
  @spec resolve_passive(term()) :: Ezagent.UriQuery.result()
  def resolve_passive(%URI{} = agent_uri) do
    case Ezagent.AgentPassiveAttributes.fetch(agent_uri) do
      {:ok, passive?} -> {:ok, passive?}
      :none -> {:ok, passive_from_snapshot(agent_uri)}
    end
  end

  def resolve_passive(_), do: {:ok, false}

  @doc false
  # P2 RECIPE PROVENANCE (was RF-7 `:role`): resolve the durable RECIPE NAME an
  # agent was built from — never parsed from the URI, and NOT a session role
  # (session role_name lives on the membership edge; use `:member_by_role`).
  # RESTART-SAFE LAYERING (parallel to `resolve_passive`): ETS fast path →
  # durable SNAPSHOT. A stored ETS entry is authoritative; ONLY an absent entry
  # (`:none`) falls through to the persisted `:sandbox`-slice `:recipe` so a
  # cold-loaded provenance agent still resolves after the ETS table is cleared.
  # No live `Kind.get_slice` layer: `:recipe` is IMMUTABLE after create, so the
  # snapshot is always current, and this can run on the routing hot path where a
  # cross-Kind call could stall. A miss → `:none`.
  @spec resolve_recipe(term()) :: Ezagent.UriQuery.result()
  def resolve_recipe(%URI{} = agent_uri) do
    case Ezagent.Agent.RecipeAttributes.fetch(agent_uri) do
      {:ok, recipe} -> {:ok, recipe}
      :none -> Ezagent.Agent.RecipeResolver.recipe_from_durable_snapshot(agent_uri)
    end
  end

  def resolve_recipe(_), do: :none

  # Durable passive verdict from the persisted `:sandbox` snapshot slice. Any
  # miss / non-boolean → `false` (principal). No live-Kind read (see the
  # resolver's comment for why the join hot path forbids it).
  defp passive_from_snapshot(%URI{} = agent_uri) do
    case snapshot_slice(agent_uri, :sandbox) do
      {:ok, sandbox} ->
        case Map.get(sandbox, :passive) do
          v when is_boolean(v) -> v
          _ -> false
        end

      _ ->
        false
    end
  end

  defp resolve_flavor_from_kind(%URI{} = agent_uri) do
    with {:ok, sandbox} <- kind_slice(agent_uri, :sandbox) do
      Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)
    end
  end

  @doc false
  @spec resolve_orchestrator(term()) :: Ezagent.UriQuery.result()
  def resolve_orchestrator(%URI{scheme: "session"} = session_uri) do
    with {:ok, working_copy} <- template_working_copy(session_uri) do
      uri_result(Map.get(working_copy, :orchestrator_uri))
    end
  end

  def resolve_orchestrator(_), do: :none

  @doc false
  @spec resolve_member_by_role(term()) :: Ezagent.UriQuery.result()
  def resolve_member_by_role({%URI{scheme: "session"} = session_uri, role_name})
      when is_binary(role_name) do
    with {:ok, chat_slice} <- kind_slice(session_uri, :session) do
      case Session.role_name_to_uri(Map.get(chat_slice, :members, %{}), role_name) do
        %URI{} = member_uri -> {:ok, member_uri}
        nil -> :none
      end
    end
  end

  def resolve_member_by_role(_), do: :none

  @doc false
  @spec resolve_session_template(term()) :: Ezagent.UriQuery.result()
  def resolve_session_template(%URI{scheme: "session"} = session_uri) do
    with {:ok, working_copy} <- template_working_copy(session_uri) do
      uri_result(Map.get(working_copy, :session_template_uri))
    end
  end

  def resolve_session_template(_), do: :none

  defp template_working_copy(%URI{} = session_uri) do
    with {:ok, chat_slice} <- kind_slice(session_uri, :session) do
      {:ok, Session.template_working_copy(chat_slice)}
    end
  end

  defp kind_slice(%URI{} = uri, slice_key) when is_atom(slice_key) do
    case Ezagent.Kind.get_slice(uri, slice_key) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      {:ok, _} -> :none
      {:error, :not_found} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp kind_slice_with_snapshot(%URI{} = uri, slice_key) when is_atom(slice_key) do
    case kind_slice(uri, slice_key) do
      :none -> snapshot_slice(uri, slice_key)
      other -> other
    end
  end

  defp snapshot_slice(%URI{} = uri, slice_key) do
    case Ezagent.SnapshotStore.latest(uri) do
      {:ok, %{state: state}} when is_map(state) ->
        case Map.get(state, slice_key) do
          slice when is_map(slice) -> {:ok, Ezagent.Kind.normalize_slice_view(slice)}
          _ -> :none
        end

      {:error, :not_found} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_field(content, key) when is_atom(key) do
    Map.get(content, key) || Map.get(content, Atom.to_string(key))
  end

  defp uri_result(%URI{} = uri), do: {:ok, uri}
  defp uri_result(_), do: :none
end
