defmodule Ezagent.Socialware.CompositionCaps do
  @moduledoc """
  Materializes declared socialware `operates` edges as narrow capabilities.

  `mint_composition_cap/5` is the lane's single mint chokepoint. It resolves the
  live role members, asserts target ownership and runtime conformance, completes
  every ISSUE before persisting the binding projection, and only then emits
  verified artifacts to their source holders. Authority denial degrades an edge;
  structural owner/conformance failures abort loudly.
  """

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.{CompositionBinding, CompositionConsent}

  @type summary :: %{active: non_neg_integer(), degraded: non_neg_integer()}

  @doc false
  @spec assert_install_authorized(URI.t(), [map()], keyword()) :: :ok | {:error, term()}
  def assert_install_authorized(%URI{} = session_uri, roles, opts)
      when is_list(roles) and is_list(opts) do
    if declared_edges(roles) == [] or Keyword.get(opts, :install_authorized?, false) do
      :ok
    else
      {:error, {:composition_install_not_owner_authorized, session_uri}}
    end
  end

  @doc "Reconcile all composition edges declared by one session working copy."
  @spec reconcile_session(URI.t(), URI.t(), URI.t(), [map()], keyword()) ::
          {:ok, summary()} | {:error, term()}
  def reconcile_session(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = configurer,
        roles,
        opts \\ []
      )
      when is_list(roles) do
    edges = declared_edges(roles)

    if edges == [] do
      previous = CompositionBinding.for_session(session_uri)

      with {:ok, _bindings} <- CompositionBinding.replace_session(session_uri, []),
           :ok <- revoke_unsupported(previous) do
        {:ok, %{active: 0, degraded: 0}}
      end
    else
      with :ok <- assert_install_authorized(session_uri, roles, opts) do
        mint_composition_cap(session_uri, workspace_uri, configurer, edges, opts)
      end
    end
  end

  @doc "Deactivate an uninstalling session's bindings and union-reconcile holders."
  @spec deactivate_session(URI.t(), atom()) :: :ok | {:error, term()}
  def deactivate_session(%URI{} = session_uri, reason \\ :uninstall) when is_atom(reason) do
    rows = CompositionBinding.for_session(session_uri)

    with {:ok, _holders} <- CompositionBinding.deactivate_session(session_uri, reason),
         :ok <- revoke_unsupported(rows) do
      :ok
    end
  end

  @doc "Deactivate edges touched by a departed role member and reconcile holders."
  @spec deactivate_member(URI.t(), URI.t(), atom()) :: :ok | {:error, term()}
  def deactivate_member(%URI{} = session_uri, %URI{} = member_uri, reason \\ :role_departure)
      when is_atom(reason) do
    rows =
      session_uri
      |> CompositionBinding.for_session()
      |> Enum.filter(fn row ->
        same_uri?(Ezagent.URI.new!(row.source_uri), member_uri) or
          same_uri?(Ezagent.URI.new!(row.target_uri), member_uri)
      end)

    with {:ok, _holders} <-
           CompositionBinding.deactivate_member(session_uri, member_uri, reason),
         :ok <- revoke_unsupported(rows) do
      :ok
    end
  end

  @doc "Queryable read model for participate-only degraded operate edges."
  @spec degraded_edges(URI.t()) :: [map()]
  def degraded_edges(%URI{} = session_uri) do
    session_uri
    |> CompositionBinding.degraded_for_session()
    |> Enum.map(fn row ->
      consent = CompositionConsent.get_by_binding(row.id)

      %{
        request_id: row.id,
        source_role: row.source_role,
        target_role: row.target_role,
        behavior: row.behavior,
        action: row.action,
        target_uri: row.target_uri,
        reason: row.inactive_reason,
        target_approval: consent && consent.target_approval,
        source_approval: consent && consent.source_approval
      }
    end)
  end

  @doc false
  @spec reconcile_consent_revocation(String.t()) :: :ok | {:error, term()}
  def reconcile_consent_revocation(binding_id) when is_binary(binding_id) do
    case CompositionBinding.get(binding_id) do
      %CompositionBinding{status: :active} = binding ->
        with {:ok, _binding} <-
               CompositionBinding.mark_degraded(binding_id, :consent_not_approved),
             :ok <- revoke_unsupported([binding]) do
          :ok
        end

      %CompositionBinding{} ->
        :ok

      nil ->
        {:error, :composition_binding_not_found}
    end
  end

  @doc """
  运行时"发一把钥匙"通用入口:给 `grantee_uri` 铸一批指向 `target_uri`(数据宿主)的
  实例精确 cap,granter 永远 = target 的 data_owner(板主人授权,#154)。

  发什么钥匙完全由 `actions` 决定 —— 同一条 issue+absorb 路,动作是参数:
  传 `[:get_tree]`(读动作)铸只读钥匙、传 `[:add_node, ...]`(增删改)铸操作钥匙。
  调用方(拉板传全动作 / 转发传读动作)自己选。

  复用 composition 现成的 `issue_item/2`(ISSUE)+ `absorb_one/2`(STORE)路,
  不碰 `CompositionBinding.replace_session`(不做整-session 重算),也不新增第二个
  absorb 调用点。target 无属主 → fail-closed,绝不回落 admin。
  """
  @spec mint_cap(URI.t(), URI.t(), module(), [atom()]) ::
          {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def mint_cap(%URI{} = grantee_uri, %URI{} = target_uri, behavior, actions)
      when is_atom(behavior) and is_list(actions) do
    grantee_instance = Ezagent.URI.instance(grantee_uri)
    target_instance = Ezagent.URI.instance(target_uri)
    workspace_uri = Ezagent.Capability.workspace_of(target_uri)

    # M2: the cap's `kind` axis must match the target URI's kind — a `:agent`
    # cap toward a `session://`/`resource://` target verifies but never matches
    # at dispatch (kind is one of the 5 match axes), i.e. a silently non-
    # authorizing cap. Derive kind from the target URI so the mint is
    # URI-kind-agnostic as promised.
    with {:ok, kind} <- target_kind(target_uri),
         {:ok, owner} <- assert_target_owner(behavior, target_uri),
         :ok <- ensure_target_owner_authority(owner, target_uri),
         # codex Fix 3: issue EVERY action's artifact BEFORE absorbing any. The
         # failure-prone step (authz/validation in `issue_item`) is thus
         # all-or-nothing — a mid-batch issue failure grants NOTHING, so an error
         # never hides a partially-granted cap set.
         {:ok, artifacts} <-
           issue_all(
             actions,
             kind,
             behavior,
             target_instance,
             workspace_uri,
             grantee_instance,
             owner
           ) do
      absorb_all(grantee_instance, artifacts)
    end
  end

  defp issue_all(actions, kind, behavior, target_instance, workspace_uri, grantee_instance, owner) do
    actions
    |> Enum.reduce_while({:ok, []}, fn action, {:ok, arts} ->
      cap = Ezagent.Capability.cap(kind, behavior, action, target_instance, workspace_uri)

      # Minimal item: for a same-owner grant `issue_item/2` takes the direct
      # `{:ok, artifact}` branch (Cap.issue caller == data_owner), so consent /
      # target_owner are never read — we still pass them for total-ness.
      item = %{source_uri: grantee_instance, cap: cap, consent: nil, target_owner: owner}

      case issue_item(item, owner) do
        {:ok, artifact, _target_required?} -> {:cont, {:ok, [artifact | arts]}}
        {:error, reason} -> {:halt, {:error, {:composition_cap_issue_failed, action, reason}}}
      end
    end)
    |> case do
      {:ok, arts} -> {:ok, Enum.reverse(arts)}
      error -> error
    end
  end

  # Absorb the already-issued artifacts. Issue is all-or-nothing above; a rare
  # absorb failure here (a store write, not authz) is reported FAITHFULLY with
  # how many landed, so a caller never mistakes an error for "nothing granted"
  # when a partial set was stored (codex Fix 3).
  defp absorb_all(grantee_instance, artifacts) do
    total = length(artifacts)

    artifacts
    |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, done} ->
      case absorb_one(grantee_instance, artifact) do
        :ok ->
          {:cont, {:ok, [artifact | done]}}

        {:error, reason} ->
          {:halt, {:error, {:composition_cap_absorb_partial, length(done), total, reason}}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  # SINGLE non-bypassable mint chokepoint. No other function in this lane calls
  # Cap.issue/3 or Identity.absorb_cap/2.
  defp mint_composition_cap(session_uri, workspace_uri, configurer, edges, opts) do
    role_members = Keyword.get(opts, :role_members) || read_role_members(session_uri)
    previous = CompositionBinding.for_session(session_uri)

    with {:ok, prepared} <-
           prepare_edges(edges, role_members, session_uri, workspace_uri, configurer),
         {:ok, issued} <- issue_all(prepared, configurer),
         classified <- classify_source_authority(issued, configurer),
         attrs <-
           Enum.map(classified, &binding_attrs(&1, session_uri, workspace_uri, configurer)),
         {:ok, bindings} <- CompositionBinding.replace_session(session_uri, attrs),
         :ok <- CompositionConsent.supersede_inactive(session_uri),
         :ok <- sync_consents(bindings, classified, configurer),
         :ok <- absorb_active(classified),
         :ok <- revoke_unsupported(previous) do
      {:ok,
       %{
         active: Enum.count(classified, &(&1.status == :active)),
         degraded: Enum.count(classified, &(&1.status == :degraded))
       }}
    end
  end

  defp prepare_edges(edges, role_members, session_uri, workspace_uri, configurer) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, prepared} ->
      with {:ok, source_uri} <- resolve_role(role_members, edge.source_role, session_uri),
           {:ok, target_uri} <- resolve_role(role_members, edge.target_role, session_uri),
           :ok <- validate_provenance(edge.provenance),
           {:ok, target_owner} <- assert_target_owner(edge.behavior, target_uri),
           :ok <- assert_target_conformance(target_uri, edge.behavior, edge.action) do
        cap =
          Ezagent.Capability.cap(
            :agent,
            edge.behavior,
            edge.action,
            Ezagent.URI.instance(target_uri),
            workspace_uri
          )

        source_owner = source_owner(source_uri)

        subject =
          edge.provenance
          |> Map.merge(%{
            session_uri: session_uri,
            source_role: edge.source_role,
            target_role: edge.target_role,
            source_uri: Ezagent.URI.instance(source_uri),
            target_uri: Ezagent.URI.instance(target_uri),
            behavior: edge.behavior,
            action: edge.action
          })

        item =
          edge
          |> Map.merge(%{
            binding_id: CompositionBinding.id_for(subject),
            source_uri: Ezagent.URI.instance(source_uri),
            target_uri: Ezagent.URI.instance(target_uri),
            source_owner: source_owner,
            target_owner: target_owner,
            cap: cap,
            configurer: configurer,
            consent: CompositionConsent.get_by_binding(CompositionBinding.id_for(subject))
          })

        {:cont, {:ok, [item | prepared]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp issue_all(prepared, configurer) do
    Enum.reduce_while(prepared, {:ok, []}, fn item, {:ok, issued} ->
      case issue_item(item, configurer) do
        {:ok, artifact, target_required?} ->
          {:cont,
           {:ok,
            [
              item
              |> Map.put(:cap, artifact)
              |> Map.put(:issuer, artifact.granted_by)
              |> Map.put(:status, :issued)
              |> Map.put(:target_required?, target_required?)
              | issued
            ]}}

        {:error, :target_consent_required} ->
          {:cont,
           {:ok,
            [
              item
              |> Map.put(:status, :degraded)
              |> Map.put(:degrade_reason, :grant_not_owner)
              |> Map.put(:target_required?, true)
              | issued
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:composition_cap_issue_failed, item.source_role, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      error -> error
    end
  end

  defp issue_item(item, configurer) do
    with :ok <- ensure_target_owner_authority(item.target_owner, item.cap.instance) do
      do_issue_item(item, configurer)
    end
  end

  defp do_issue_item(item, configurer) do
    if same_uri?(configurer, item.target_owner) do
      issue_as_target_owner(item, false)
    else
      issue_foreign_target(item)
    end
  end

  defp issue_foreign_target(item) do
    if CompositionConsent.approved?(item.consent, :target, item.target_owner) do
      issue_as_target_owner(item, true)
    else
      {:error, :target_consent_required}
    end
  end

  defp issue_as_target_owner(item, target_required?) do
    case Ezagent.Cap.issue(
           grant_authorization(item.target_owner),
           item.source_uri,
           item.cap
         ) do
      {:ok, artifact} ->
        {:ok, artifact, target_required?}

      {:error, reason} ->
        {:error, {:target_owner_issue_failed, reason}}
    end
  end

  # Data ownership is established by reviewed framework creation paths.  Make
  # that relationship an explicit admin -> owner delegation on the target Kind
  # before the owner issues composition artifacts.  The returned authority cap
  # is minted by target K.grant and stored on the owner; no data-owner rule or
  # unsigned bypass participates in issuance.
  defp ensure_target_owner_authority(%URI{} = owner, %URI{} = target) do
    Ezagent.Identity.TargetAuthority.ensure(owner, target)
  end

  defp grant_authorization(%URI{} = issuer) do
    admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(issuer) == Ezagent.URI.stable_key(admin),
      do: {:admin, issuer},
      else: {:held_by, issuer}
  end

  defp classify_source_authority(items, configurer) do
    Enum.map(items, fn item ->
      source_authorized? =
        match?(%URI{}, item.source_owner) and
          (same_uri?(item.source_owner, configurer) or
             Ezagent.Identity.Authority.manages?(configurer, item.source_uri))

      source_consented? =
        CompositionConsent.approved?(item.consent, :source, item.source_owner)

      item = Map.put(item, :source_required?, not source_authorized?)

      cond do
        item.status == :issued and (source_authorized? or source_consented?) ->
          item
          |> Map.put(:status, :active)
          |> Map.put_new(:target_required?, false)

        item.status == :issued ->
          item
          |> Map.put(:status, :degraded)
          |> Map.put(:degrade_reason, :foreign_source)
          |> Map.put_new(:target_required?, false)

        true ->
          item
          |> Map.put_new(:target_required?, true)
      end
    end)
  end

  defp absorb_active(items) do
    Enum.reduce_while(items, :ok, fn
      %{status: :active, source_uri: source_uri, cap: artifact} = item, :ok ->
        identity = CompositionBinding.cap_identity(artifact)

        cond do
          not CompositionBinding.supported?(source_uri, identity) ->
            {:halt, {:error, :composition_binding_not_current}}

          not consent_current?(item) ->
            {:halt, {:error, :composition_consent_not_current}}

          true ->
            case absorb_one(source_uri, artifact) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:composition_cap_absorb_failed, reason}}}
            end
        end

      _item, :ok ->
        {:cont, :ok}
    end)
  end

  # SINGLE non-bypassable STORE hand-off. This is the lane's ONLY call to
  # `Ezagent.Identity.absorb_cap/2`; every self-store path (the session-reconcile
  # `absorb_active/1` and the runtime `mint_cap/4` entry) routes through here so
  # the I12 paradigm lock keeps counting exactly one absorb producer in this file.
  defp absorb_one(source_uri, artifact) do
    Ezagent.Identity.absorb_cap(source_uri, artifact)
  end

  defp revoke_unsupported(rows) do
    rows
    |> Enum.uniq_by(&{&1.source_uri, &1.cap_identity})
    |> Enum.reduce_while(:ok, fn row, :ok ->
      source_uri = Ezagent.URI.new!(row.source_uri)

      if CompositionBinding.supported?(source_uri, row.cap_identity) do
        {:cont, :ok}
      else
        cap =
          Ezagent.Capability.cap(
            :agent,
            String.to_existing_atom(row.behavior),
            String.to_existing_atom(row.action),
            Ezagent.URI.new!(row.target_uri),
            Ezagent.URI.new!(row.workspace_uri)
          )

        case Ezagent.Identity.Grant.revoke_cap(
               source_uri,
               cap,
               {:held_by, Ezagent.URI.new!(row.issuer_uri)}
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:composition_cap_revoke_failed, reason}}}
        end
      end
    end)
  end

  defp binding_attrs(item, session_uri, workspace_uri, configurer) do
    item.provenance
    |> Map.merge(%{
      session_uri: session_uri,
      source_role: item.source_role,
      target_role: item.target_role,
      source_uri: item.source_uri,
      target_uri: item.target_uri,
      workspace_uri: workspace_uri,
      behavior: item.behavior,
      action: item.action,
      issuer_uri: Map.get(item, :issuer, configurer),
      cap: item.cap,
      status: item.status,
      degrade_reason: Map.get(item, :degrade_reason)
    })
  end

  defp sync_consents(bindings, classified, configurer) do
    items_by_id = Map.new(classified, &{&1.binding_id, &1})

    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      item = Map.fetch!(items_by_id, binding.id)

      case CompositionConsent.sync(binding, %{
             configurer: configurer,
             target_owner: item.target_owner,
             source_owner: item.source_owner,
             target_required?: item.target_required?,
             source_required?: item.source_required?
           }) do
        {:ok, _consent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:composition_consent_sync_failed, reason}}}
      end
    end)
  end

  defp consent_current?(item) do
    consent = CompositionConsent.get_by_binding(item.binding_id)

    CompositionConsent.approved?(consent, :target, item.target_owner) and
      CompositionConsent.approved?(consent, :source, item.source_owner)
  end

  # M2: derive the cap `kind` atom from the target URI's per-tenant type segment
  # (`entity://…/agent/…` → `:agent`, `session://…` → `:session`, `resource://…`
  # → `:resource`), so the minted cap's kind axis matches the target Kind. An
  # untyped or unknown-kind target fails closed (no silently non-authorizing cap).
  # Derive a target's cap `kind` axis URI-agnostically. `Ezagent.URI.type/1`
  # returns the FIRST path segment, which is the kind ONLY for `entity://`
  # (agent/user/worker share that scheme). For the other unified schemes
  # (`session://`, `resource://`, `template://`) the first path segment is a
  # SUBTYPE (`session://acme/chat/s1` → "chat"), NOT the kind — the kind is the
  # SCHEME itself (`:session`). Using the subtype minted a cap whose `kind` axis
  # never matches at dispatch = a silently dead cap. So: entity → type segment,
  # every other scheme → the scheme. No per-scheme special-casing beyond this
  # container-vs-1:1 split.
  defp target_kind(%URI{scheme: "entity"} = target_uri) do
    case Ezagent.URI.type(target_uri) do
      {:ok, type} -> to_kind_atom(type)
      :error -> {:error, {:untyped_target, target_uri}}
    end
  end

  defp target_kind(%URI{scheme: scheme}) when is_binary(scheme) and scheme != "",
    do: to_kind_atom(scheme)

  defp target_kind(%URI{} = target_uri), do: {:error, {:untyped_target, target_uri}}

  defp to_kind_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, {:unknown_target_kind, str}}
  end

  defp assert_target_owner(behavior, target_uri) do
    if Code.ensure_loaded?(behavior) do
      case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target_uri)) do
        %URI{} = owner -> {:ok, owner}
        _ -> {:error, {:operate_target_ownerless, target_uri, behavior}}
      end
    else
      {:error, {:operate_target_ownerless, target_uri, behavior}}
    end
  end

  defp source_owner(source_uri) do
    case Ezagent.CapabilityRegistry.data_owner_of(
           Ezagent.ActionSet.ApiKeys,
           Ezagent.URI.instance(source_uri)
         ) do
      %URI{} = owner -> owner
      _ -> nil
    end
  end

  defp assert_target_conformance(target_uri, behavior, action) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(target_uri),
         {:ok, %{state: state}} when is_map(state) <- Ezagent.Kind.runtime_view(pid),
         {:ok, resolved} <-
           Ezagent.Kind.BehaviorSet.resolve_action(Ezagent.Entity.Agent, action, state),
         true <- resolved == behavior,
         true <- runtime_instance_member?(behavior, state) do
      :ok
    else
      _ -> {:error, {:operate_target_not_conformant, target_uri, behavior, action}}
    end
  end

  defp runtime_instance_member?(behavior, state) do
    declared? = behavior in Ezagent.Kind.behaviors_of(Ezagent.Entity.Agent)

    not declared? or
      Ezagent.Kind.BehaviorSet.member?(
        behavior,
        Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Agent, state)
      )
  end

  defp resolve_role(role_members, role_name, session_uri) do
    case Map.get(role_members, role_name) || Members.role_name_to_uri(role_members, role_name) do
      %URI{} = uri -> {:ok, uri}
      _ -> {:error, {:operate_role_unresolved, session_uri, role_name}}
    end
  end

  defp validate_provenance(%{
         install_id: install_id,
         definition_config_id: config_id,
         definition_content_hash: content_hash
       })
       when is_binary(install_id) and install_id != "" and is_binary(config_id) and
              config_id != "" and is_binary(content_hash) and content_hash != "",
       do: :ok

  defp validate_provenance(_), do: {:error, :operate_edge_provenance_missing}

  defp read_role_members(session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
      _ -> %{}
    end
  end

  defp declared_edges(roles) do
    Enum.flat_map(roles, fn role ->
      source_role = map_get(role, :role_name)
      provenance = map_get(role, :composition_provenance)

      role
      |> map_get(:operates, [])
      |> Enum.map(fn edge ->
        %{
          source_role: source_role,
          target_role: map_get(edge, :role),
          behavior: map_get(edge, :behavior),
          action: map_get(edge, :action),
          provenance: provenance
        }
      end)
    end)
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_map, _key, default), do: default

  defp same_uri?(left, right),
    do:
      Ezagent.URI.stable_key(Ezagent.URI.instance(left)) ==
        Ezagent.URI.stable_key(Ezagent.URI.instance(right))
end
