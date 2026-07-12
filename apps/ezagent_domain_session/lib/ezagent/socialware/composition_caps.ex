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
  alias Ezagent.Socialware.CompositionBinding

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
      %{
        source_role: row.source_role,
        target_role: row.target_role,
        behavior: row.behavior,
        action: row.action,
        target_uri: row.target_uri,
        reason: row.inactive_reason
      }
    end)
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
         attrs <- Enum.map(classified, &binding_attrs(&1, session_uri, workspace_uri, configurer)),
         {:ok, _bindings} <- CompositionBinding.replace_session(session_uri, attrs),
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
           {:ok, _owner} <- assert_target_owner(edge.behavior, target_uri),
           :ok <- assert_target_conformance(target_uri, edge.behavior, edge.action) do
        cap =
          Ezagent.Capability.cap(
            :agent,
            edge.behavior,
            edge.action,
            Ezagent.URI.instance(target_uri),
            workspace_uri
          )

        item =
          edge
          |> Map.merge(%{
            source_uri: Ezagent.URI.instance(source_uri),
            target_uri: Ezagent.URI.instance(target_uri),
            cap: cap,
            configurer: configurer
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
      case Ezagent.Cap.issue({:held_by, configurer}, item.source_uri, item.cap) do
        {:ok, artifact} ->
          {:cont, {:ok, [item |> Map.put(:cap, artifact) |> Map.put(:status, :issued) | issued]}}

        {:error, :grant_not_owner} ->
          {:cont,
           {:ok,
            [
              item
              |> Map.put(:status, :degraded)
              |> Map.put(:degrade_reason, :grant_not_owner)
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

  defp classify_source_authority(items, configurer) do
    Enum.map(items, fn
      %{status: :degraded} = item ->
        item

      %{status: :issued, source_uri: source_uri} = item ->
        case Ezagent.CapabilityRegistry.data_owner_of(
               Ezagent.ActionSet.ApiKeys,
               Ezagent.URI.instance(source_uri)
             ) do
          %URI{} = owner ->
            if same_uri?(owner, configurer) or
                 Ezagent.Identity.Authority.manages?(configurer, source_uri) do
              %{item | status: :active}
            else
              item
              |> Map.put(:status, :degraded)
              |> Map.put(:degrade_reason, :foreign_source)
            end

          _ ->
            item
            |> Map.put(:status, :degraded)
            |> Map.put(:degrade_reason, :foreign_source)
        end
    end)
  end

  defp absorb_active(items) do
    Enum.reduce_while(items, :ok, fn
      %{status: :active, source_uri: source_uri, cap: artifact}, :ok ->
        identity = CompositionBinding.cap_identity(artifact)

        cond do
          not CompositionBinding.supported?(source_uri, identity) ->
            {:halt, {:error, :composition_binding_not_current}}

          true ->
            case Ezagent.Identity.absorb_cap(source_uri, artifact) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:composition_cap_absorb_failed, reason}}}
            end
        end

      _item, :ok ->
        {:cont, :ok}
    end)
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
               {:rule, :socialware_composition_reconcile, Ezagent.URI.new!(row.issuer_uri)}
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
      issuer_uri: configurer,
      cap: item.cap,
      status: item.status,
      degrade_reason: Map.get(item, :degrade_reason)
    })
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

  defp assert_target_conformance(target_uri, behavior, action) do
    with {:ok, pid} <- Ezagent.KindRegistry.lookup(target_uri),
         %{state: state} when is_map(state) <- :sys.get_state(pid),
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
    case Ezagent.Kind.get_slice(session_uri, :session) do
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
