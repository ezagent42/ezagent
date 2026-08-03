defmodule Ezagent.Entity.Agent.TemplateSpawn.Cascade do
  @moduledoc false

  # #17 cascade PR-3 — activate PR-2's layered file materializer at the domain spawn
  # bridge. Callers may provide the durable resolution INPUTS under `cascade_resolution`;
  # this bridge resolves them immediately before the Template Class sees data, so normal
  # spawn paths do not need to hand-author `tmpl["cascade"]`.
  #
  # #201-cred (codex r2 HIGH-1) — NO GRANT IS MINTED HERE. This bridge only
  # RESOLVES the source and AUTHORIZES it (read-only cap check), producing a
  # plain-data pending-grant descriptor threaded to the flavor plugin inside
  # the cascade map (`:pending_grant`, file flavors) and the
  # `cascade_resolution` (slice flavors). The DURABLE mint is deferred to the
  # created-winner's materialization boundary (`Ezagent.Credential.GrantMint`),
  # AFTER the immutable `:started ∧ created?` receipt — a losing / adopting /
  # rehydrating / exception-raising attempt therefore never mints, and no
  # compensate-the-loser machinery exists to fail.
  def resolve_content(
        content,
        template_class,
        agent_uri,
        spawned_by_uri,
        workspace_uri,
        flavor,
        opts
      )
      when is_map(content) do
    content = enforce_session_local_policy(content)

    cond do
      is_map(content_field(content, :cascade)) ->
        {:ok, content}

      is_map(content_field(content, :cascade_resolution)) ->
        with {:ok, cascade, resolved} <-
               build_cascade(
                 with_self_aware_dir_fns(content_field(content, :cascade_resolution), content),
                 agent_uri,
                 spawned_by_uri,
                 workspace_uri,
                 flavor
               ),
             {:ok, pending_grant} <-
               build_pending_grant(
                 agent_uri,
                 resolved.secret_source,
                 opts,
                 content_field(content, :cascade_resolution)
               ) do
          content =
            content
            |> Map.put(:cascade, put_pending_grant(cascade, pending_grant))
            |> put_selected_credential_source(resolved.secret_source, pending_grant)

          {:ok, content}
        end

      is_nil(content_field(content, :cascade_resolution)) ->
        maybe_resolve_default_cascade_content(
          content,
          template_class,
          agent_uri,
          spawned_by_uri,
          workspace_uri,
          flavor,
          opts
        )

      true ->
        {:error, {:invalid_cascade_resolution, content_field(content, :cascade_resolution)}}
    end
  end

  defp maybe_resolve_default_cascade_content(
         content,
         template_class,
         agent_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         opts
       ) do
    source_template_uri = Keyword.get(opts, :source_template_uri)
    credential_adapter = credential_adapter_kind(template_class)

    if credential_adapter != :none and
         default_cascade_configured?(credential_adapter, content, source_template_uri) do
      # 2026-06-07 file-flavor-create-cascade — `workspace_layer_uri` is the
      # source_template_uri ONLY when one is threaded (orchestrator/fork path).
      # The unified-create path resolves a config home from the content's own
      # `config_dir` (no shared workspace base template exists), so it passes
      # NO source_template_uri; the workspace config layer is then simply absent
      # (`default_layer_dir_for(nil) → :skip`) rather than a dead persisted URI.
      resolution =
        %{
          owner_uri: spawned_by_uri,
          workspace_uri: workspace_uri,
          workspace_layer_uri: source_template_uri,
          flavor: flavor,
          credential_source_policy: content_field(content, :credential_source_policy),
          credential_required?: credential_required?(credential_adapter, content),
          explicit_source: Keyword.get(opts, :explicit_source)
        }
        |> with_self_aware_dir_fns(content)

      with {:ok, cascade, resolved} <-
             build_cascade(resolution, agent_uri, spawned_by_uri, workspace_uri, flavor),
           {:ok, content} <-
             put_default_cascade_if_source_present(
               content,
               cascade,
               resolved,
               agent_uri,
               opts,
               resolution
             ) do
        {:ok, content}
      end
    else
      {:ok, content}
    end
  end

  defp put_default_cascade_if_source_present(
         content,
         cascade,
         %{secret_source: nil},
         _agent,
         _opts,
         resolution
       ) do
    if session_local_policy?(resolution) do
      {:ok,
       content
       |> Map.put(:cascade_resolution, resolution)
       |> Map.put(:cascade, cascade)}
    else
      {:ok, content}
    end
  end

  defp put_default_cascade_if_source_present(
         content,
         cascade,
         %{secret_source: source},
         agent_uri,
         opts,
         resolution
       ) do
    with {:ok, pending_grant} <- build_pending_grant(agent_uri, source, opts, resolution) do
      content =
        content
        |> Map.put(
          :cascade_resolution,
          resolution
          |> Map.put(:credential_source_uri, source)
          |> put_pending_grant_entry(pending_grant)
        )
        |> Map.put(:cascade, put_pending_grant(cascade, pending_grant))

      {:ok, content}
    end
  end

  defp credential_adapter_kind(template_class) do
    cond do
      Ezagent.Agent.CredentialAdapter.credentialled?(template_class) -> :file
      Ezagent.Agent.CredentialSliceAdapter.credentialled?(template_class) -> :slice
      true -> :none
    end
  end

  defp credential_required_by_default?(:slice), do: true
  defp credential_required_by_default?(:file), do: false

  # A member may opt OUT of the required-by-default credential (e.g. a curl LLM
  # member declared credential_optional so it keyless-spawns in deployments with
  # no credential source). Authored under recipe.config → content.credential_optional.
  defp credential_required?(adapter, content) do
    if content_field(content, :credential_optional) in [true, "true"] do
      false
    else
      credential_required_by_default?(adapter)
    end
  end

  defp default_cascade_configured?(:slice, _content, %URI{}), do: true
  defp default_cascade_configured?(:slice, _content, _), do: false

  # A file-flavor has a resolvable config home iff the content carries a
  # `config_dir` (the unified-create path — no source template needed) OR a
  # threaded `source_template_uri` resolves one (the orchestrator/fork path).
  defp default_cascade_configured?(:file, content, source_template_uri) do
    case content_field(content, :config_dir) do
      dir when is_binary(dir) and dir != "" ->
        true

      _ ->
        case source_template_uri do
          %URI{} = uri ->
            # A SELF source's config_dir IS this content's — already checked
            # absent above, so the layer is absent. Never self-call to find
            # out (F2/#1460 — see with_self_aware_dir_fns/2).
            if self_kind?(uri) do
              false
            else
              case Ezagent.UriQuery.resolve(:config_dir, uri) do
                {:ok, dir} when is_binary(dir) and dir != "" -> true
                _ -> false
              end
            end

          _ ->
            false
        end
    end
  end

  defp build_cascade(resolution, agent_uri, spawned_by_uri, workspace_uri, flavor) do
    with {:ok, layer_dir_for} <-
           cascade_function(resolution, :layer_dir_for, &default_layer_dir_for/1),
         {:ok, source_dir_for} <-
           cascade_function(resolution, :source_dir_for, &default_source_dir_for/1),
         {:ok, owner_uri} <-
           cascade_uri(resolution, :owner_uri, spawned_by_uri, required?: true),
         {:ok, resolved_workspace_uri} <-
           cascade_uri(resolution, :workspace_uri, workspace_uri, required?: false),
         {:ok, session_uri} <- cascade_uri(resolution, :session_uri, nil, required?: false),
         {:ok, explicit_source} <-
           cascade_uri(resolution, :explicit_source, nil, required?: false),
         {:ok, resolved} <-
           Ezagent.Credential.Resolver.resolve_layers(
             resolver_inputs(
               resolution,
               agent_uri,
               owner_uri,
               resolved_workspace_uri,
               session_uri,
               explicit_source,
               flavor
             )
           ),
         {:ok, layer_dirs} <- materializer_layer_dirs(resolved.config_layers, layer_dir_for) do
      {:ok, %{layer_dirs: layer_dirs, source_dir_for: source_dir_for}, resolved}
    end
  end

  defp cascade_function(resolution, key, default) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      nil -> {:ok, default}
      fun when is_function(fun, 1) -> {:ok, fun}
      _ -> {:error, {:missing_cascade_resolution_function, key}}
    end
  end

  # F2 / #1460 — `template.instantiate` runs IN-PROCESS inside the template
  # Kind's own dispatch (Behavior.Template.handle_instantiate NEVER dispatches
  # `:read` back to its own Kind — codex rev-5 HIGH-2 deadlock avoidance). When
  # a cascade layer's source names that SAME Kind (the unified-create path
  # threads `source_template_uri: self_uri`), the default UriQuery →
  # `Kind.get_slice` dir resolution below self-`GenServer.call`s and exits
  # `{:calling_self}` — the spawn aborts with `:cascade_layer_dir_failed`
  # before the Template Class ever runs.
  #
  # The data being resolved (the template's config home) is already IN HAND:
  # it lives in the very content this dispatch is resolving. Serve
  # self-referencing layers from that content; delegate everything else to the
  # defaults unchanged. Caller-injected functions always win (`put_new`), so
  # lanes that hand-author their resolution (orchestrator, tests) are
  # untouched; the wrappers are also a no-op for cross-Kind sources (a live
  # parent template resolves via the normal UriQuery path).
  defp with_self_aware_dir_fns(resolution, content) when is_map(resolution) do
    resolution
    |> Map.put_new(:layer_dir_for, self_aware_layer_dir_for(content))
    |> Map.put_new(:source_dir_for, self_aware_source_dir_for(content))
  end

  defp self_aware_layer_dir_for(content) do
    fn
      %{source: %URI{} = uri} = layer ->
        if self_kind?(uri) do
          case content_field(content, :config_dir) do
            dir when is_binary(dir) and dir != "" ->
              {:ok, %{dir: dir, protected: [], mandatory: []}}

            _ ->
              :skip
          end
        else
          default_layer_dir_for(layer)
        end

      other ->
        default_layer_dir_for(other)
    end
  end

  defp self_aware_source_dir_for(content) do
    fn
      %URI{} = source ->
        if self_kind?(source) do
          self_source_dir(content, source)
        else
          default_source_dir_for(source)
        end

      source when is_binary(source) ->
        case Ezagent.URI.new!(source) do
          %URI{} = uri ->
            if self_kind?(uri) do
              self_source_dir(content, uri)
            else
              default_source_dir_for(source)
            end
        end

      other ->
        default_source_dir_for(other)
    end
  end

  defp self_source_dir(content, %URI{} = source) do
    case content_field(content, :config_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, {:source_config_dir_absent, source}}
    end
  end

  # True iff `uri` is registered to the CURRENTLY EXECUTING process — i.e. the
  # Kind inside whose dispatch this cascade resolution is running. A
  # cross-process slice read of such a URI would be a self-`GenServer.call`.
  defp self_kind?(%URI{} = uri) do
    Ezagent.Kind.self?(uri)
  end

  defp default_layer_dir_for(%{source: %URI{} = uri}) do
    case Ezagent.UriQuery.resolve(:config_dir, uri) do
      {:ok, dir} when is_binary(dir) -> {:ok, %{dir: dir, protected: [], mandatory: []}}
      :none -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_layer_dir_for(_layer), do: :skip

  defp default_source_dir_for(%URI{} = source), do: default_config_dir_for_source(source)

  defp default_source_dir_for(source) when is_binary(source) do
    source
    |> Ezagent.URI.new!()
    |> default_config_dir_for_source()
  end

  defp default_config_dir_for_source(%URI{} = source) do
    case Ezagent.UriQuery.resolve(:config_dir, source) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      :none -> {:error, {:source_config_dir_absent, source}}
      {:error, reason} -> {:error, reason}
    end
  end

  # #201-cred — AUTHORIZE (read-only) and produce the pending-grant descriptor;
  # the durable mint is deferred to the created-winner (`GrantMint`). Returns
  # `{:ok, pending | nil}` (nil = no source to authorize) or `{:error, reason}`.
  defp build_pending_grant(_agent_uri, nil, _opts, _resolution), do: {:ok, nil}

  defp build_pending_grant(%URI{} = agent_uri, %URI{} = source, opts, resolution) do
    caller = Keyword.get(opts, :caller)
    caps = Keyword.get(opts, :caps)

    result =
      cond do
        match?(%URI{}, caller) and is_list(caps) ->
          Ezagent.Credential.Resolver.authorize_grant(%{
            agent_uri: agent_uri,
            source: source,
            caller: caller,
            authenticated_principal: caller,
            caps: caps
          })

        match?(%URI{}, caller) and match?(%MapSet{}, caps) ->
          Ezagent.Credential.Resolver.authorize_grant(%{
            agent_uri: agent_uri,
            source: source,
            caller: caller,
            authenticated_principal: caller,
            caps: MapSet.to_list(caps)
          })

        true ->
          {:error, :missing_cascade_authorization}
      end

    case result do
      {:error, :missing_cascade_authorization} ->
        workspace_shared_pending(agent_uri, source, caller, resolution)

      {:error, {:source_unauthorized, ^source}} ->
        workspace_shared_pending(agent_uri, source, caller, resolution)

      other ->
        other
    end
  end

  # The no-cap workspace-shared fallback: a pending descriptor whose shared-source
  # registration is RE-validated at mint time (`GrantMint.mint/2`).
  defp workspace_shared_pending(
         %URI{} = agent_uri,
         %URI{} = source,
         %URI{} = _caller,
         resolution
       ) do
    with nil <- Map.get(resolution, :explicit_source) || Map.get(resolution, "explicit_source"),
         {:ok, workspace_uri} <- cascade_uri(resolution, :workspace_uri, nil, required?: true),
         flavor when is_binary(flavor) <-
           Map.get(resolution, :flavor) || Map.get(resolution, "flavor"),
         true <-
           Ezagent.Capability.workspace_of(agent_uri) == Ezagent.Capability.workspace_of(source),
         %Ezagent.Credential.WorkspaceSharedSource{} = row <-
           Ezagent.Credential.WorkspaceSharedSource.get(URI.to_string(workspace_uri), flavor),
         true <- row.source_uri == URI.to_string(source),
         set_by when is_binary(set_by) and set_by != "" <- row.set_by do
      {:ok,
       %{kind: :workspace_shared, workspace_uri: workspace_uri, flavor: flavor, source: source}}
    else
      _ -> {:error, {:source_unauthorized, source}}
    end
  end

  defp workspace_shared_pending(_agent_uri, source, _caller, _resolution) do
    {:error, {:source_unauthorized, source}}
  end

  defp put_pending_grant(cascade, nil), do: cascade

  defp put_pending_grant(cascade, %{} = pending),
    do: Map.put(cascade, :pending_grant, pending)

  defp put_pending_grant_entry(resolution, nil), do: resolution

  defp put_pending_grant_entry(resolution, %{} = pending),
    do: Map.put(resolution, :pending_grant, pending)

  defp put_selected_credential_source(content, nil, _pending), do: content

  defp put_selected_credential_source(content, %URI{} = source, pending_grant) do
    key =
      if Map.has_key?(content, :cascade_resolution) do
        :cascade_resolution
      else
        "cascade_resolution"
      end

    case Map.get(content, key) do
      resolution when is_map(resolution) ->
        updated =
          resolution
          |> Map.put(:credential_source_uri, source)
          |> put_pending_grant_entry(pending_grant)

        Map.put(content, key, updated)

      _ ->
        content
    end
  end

  defp resolver_inputs(
         resolution,
         agent_uri,
         owner_uri,
         workspace_uri,
         session_uri,
         explicit_source,
         flavor
       ) do
    %{
      agent_uri: agent_uri,
      owner_uri: owner_uri,
      workspace_uri: workspace_uri,
      session_uri: session_uri,
      explicit_source: explicit_source,
      flavor: Map.get(resolution, :flavor) || Map.get(resolution, "flavor") || flavor,
      credential_source_policy:
        Map.get(resolution, :credential_source_policy) ||
          Map.get(resolution, "credential_source_policy"),
      credential_required?: Map.get(resolution, :credential_required?, true)
    }
    |> maybe_put_uri_input(resolution, :workspace_layer_uri)
    |> maybe_put_uri_input(resolution, :user_layer_uri)
    |> maybe_put_uri_input(resolution, :session_layer_uri)
    |> maybe_put_resolver_fun(resolution, :source_available?)
    |> maybe_put_resolver_fun(resolution, :user_source_lookup)
    |> maybe_put_resolver_fun(resolution, :workspace_shared_lookup)
  end

  defp maybe_put_uri_input(inputs, resolution, key) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      %URI{} = uri -> Map.put(inputs, key, uri)
      value when is_binary(value) and value != "" -> Map.put(inputs, key, Ezagent.URI.new!(value))
      _ -> inputs
    end
  end

  defp maybe_put_resolver_fun(inputs, resolution, key) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
      fun when is_function(fun) -> Map.put(inputs, key, fun)
      _ -> inputs
    end
  end

  defp materializer_layer_dirs(config_layers, layer_dir_for) do
    config_layers
    |> Enum.reduce_while({:ok, []}, fn layer, {:ok, acc} ->
      case layer_dir_for.(layer) do
        :skip ->
          {:cont, {:ok, acc}}

        nil ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, dir} when is_binary(dir) ->
          {:cont, {:ok, acc ++ [%{dir: dir, protected: [], mandatory: []}]}}

        {:ok, %{dir: dir} = layer_dir} when is_binary(dir) ->
          {:cont, {:ok, acc ++ [normalize_layer_dir(layer_dir)]}}

        {:error, reason} ->
          {:halt, {:error, {:cascade_layer_dir_failed, layer, reason}}}

        other ->
          {:halt, {:error, {:invalid_cascade_layer_dir, layer, other}}}
      end
    end)
  end

  defp normalize_layer_dir(layer_dir) do
    layer_dir
    |> Map.put_new(:protected, [])
    |> Map.put_new(:mandatory, [])
  end

  defp cascade_uri(resolution, key, default, required?: required?) do
    case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) || default do
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> {:ok, Ezagent.URI.new!(s)}
      nil when not required? -> {:ok, nil}
      nil -> {:error, {:missing_cascade_resolution_uri, key}}
    end
  end

  defp content_field(content, key) when is_atom(key) do
    case Map.get(content, key) do
      nil -> Map.get(content, Atom.to_string(key))
      v -> v
    end
  end

  defp enforce_session_local_policy(content) do
    if session_local_policy?(content) do
      content = Map.drop(content, [:cascade, "cascade"])

      case content_field(content, :cascade_resolution) do
        resolution when is_map(resolution) ->
          sanitized =
            resolution
            |> Map.drop([
              :explicit_source,
              "explicit_source",
              :credential_source_uri,
              "credential_source_uri",
              :pending_grant,
              "pending_grant",
              :credential_source_policy,
              "credential_source_policy"
            ])
            |> Map.put(:credential_source_policy, :session_local)

          content
          |> Map.drop([:cascade_resolution, "cascade_resolution"])
          |> Map.put(:cascade_resolution, sanitized)

        _ ->
          content
      end
    else
      content
    end
  end

  defp session_local_policy?(map) when is_map(map) do
    content_field(map, :credential_source_policy) in [:session_local, "session_local"]
  end

  @doc false
  def sanitize_respawn_template_data(respawn_data, template_content)
      when is_map(respawn_data) and is_map(template_content) do
    respawn_data
    |> Map.drop(["cascade", :cascade])
    |> put_respawn_cascade_resolution(template_content)
  end

  def sanitize_respawn_template_data(respawn_data, _template_content), do: respawn_data

  defp put_respawn_cascade_resolution(respawn_data, template_content) do
    case content_field(template_content, :cascade_resolution) do
      resolution when is_map(resolution) ->
        case cascade_resolution_snapshot(resolution) do
          snapshot when map_size(snapshot) > 0 ->
            Map.put(respawn_data, "cascade_resolution", snapshot)

          _ ->
            respawn_data
        end

      _ ->
        respawn_data
    end
  end

  defp cascade_resolution_snapshot(resolution) do
    [
      :owner_uri,
      :workspace_uri,
      :session_uri,
      :explicit_source,
      :credential_source_uri,
      :credential_source_policy,
      :workspace_layer_uri,
      :user_layer_uri,
      :session_layer_uri
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
        %URI{} = uri ->
          Map.put(acc, Atom.to_string(key), uri_to_respawn_value(uri))

        value when is_binary(value) and value != "" ->
          Map.put(acc, Atom.to_string(key), value)

        value when key == :credential_source_policy and value == :session_local ->
          Map.put(acc, Atom.to_string(key), Atom.to_string(value))

        _ ->
          acc
      end
    end)
  end

  defp uri_to_respawn_value(%URI{} = uri), do: URI.to_string(uri)

  def put_respawn_flavor(meta, template_content_map) when is_map(meta) do
    case Map.get(template_content_map, :flavor) || Map.get(template_content_map, "flavor") do
      flavor when is_binary(flavor) and flavor != "" ->
        case Map.get(meta, :respawn_template_data) do
          data when is_map(data) ->
            respawn_data =
              data
              |> sanitize_respawn_template_data(template_content_map)
              |> Map.put_new("flavor", flavor)

            Map.put(meta, :respawn_template_data, respawn_data)

          _ ->
            meta
        end

      _ ->
        meta
    end
  end
end
