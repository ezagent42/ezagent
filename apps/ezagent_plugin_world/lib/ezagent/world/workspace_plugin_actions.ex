defmodule Ezagent.World.WorkspacePluginActions do
  @moduledoc """
  Socket-side dispatch handlers for world workspace/plugin/profile surfaces.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2]

  alias Ezagent.World.{CredentialCascade, WorkspacePluginData}

  @default_world_template_installs ["chat"]
  @foundation_socialware_refs ["chat", "orchestrator", "socialware"]

  @doc "Route a workspace/plugin/profile world action to its handler."
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "profile.display_name.edit", _args) do
    put_world_state(socket, %{"editing_display_name" => true}, "ok")
  end

  def handle_dispatch(socket, "profile.display_name.cancel", _args) do
    put_world_state(socket, %{"editing_display_name" => false}, "ok")
  end

  def handle_dispatch(socket, "profile.display_name.save", %{"display_name" => name})
      when is_binary(name) do
    save_display_name(socket, name)
  end

  def handle_dispatch(socket, "feishu.bind", %{"open_id" => open_id, "user_uri" => user_uri})
      when is_binary(open_id) and is_binary(user_uri) do
    bind_feishu_user(socket, open_id, user_uri)
  end

  def handle_dispatch(socket, "feishu.unbind", %{"open_id" => open_id}) when is_binary(open_id) do
    unbind_feishu_user(socket, open_id)
  end

  def handle_dispatch(socket, "workspace.member.remove", %{"member_uri" => member_uri})
      when is_binary(member_uri) do
    remove_workspace_member(socket, member_uri)
  end

  def handle_dispatch(socket, "kb.query", %{"agent_uri" => agent_uri, "query" => query} = args)
      when is_binary(agent_uri) and is_binary(query) do
    query_kb(socket, agent_uri, query, integer_arg(args, "k", 5))
  end

  def handle_dispatch(socket, "kb.ingest", %{
        "agent_uri" => agent_uri,
        "source_uri" => source_uri
      })
      when is_binary(agent_uri) and is_binary(source_uri) do
    ingest_kb(socket, agent_uri, source_uri)
  end

  def handle_dispatch(socket, "workspace.invite.mint", args) when is_map(args) do
    mint_workspace_invite(socket, args)
  end

  def handle_dispatch(socket, "workspace.invite.revoke", %{"code" => code})
      when is_binary(code) do
    revoke_workspace_invite(socket, code)
  end

  def handle_dispatch(socket, "workspace.template.save", %{"template" => params})
      when is_map(params) do
    save_session_template(socket, params)
  end

  def handle_dispatch(socket, "auto_derive.default_source.set", %{"default_source" => params})
      when is_map(params) do
    set_default_source(socket, params)
  end

  def handle_dispatch(socket, "auto_derive.credential_grant.revoke", %{"agent_uri" => agent_uri})
      when is_binary(agent_uri) do
    revoke_credential_grant(socket, agent_uri)
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  @doc "Save the current entity display name."
  @spec save_display_name(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def save_display_name(socket, name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        put_world_state(
          socket,
          %{"profile_error" => "display_name_required"},
          "error:display_name_required"
        )

      true ->
        entity_uri = socket.assigns.current_entity_uri
        entity_uri_str = URI.to_string(entity_uri)

        case Ezagent.Entity.Profile.upsert(%{entity_uri: entity_uri_str, display_name: name}) do
          {:ok, _profile} ->
            put_world_state(
              socket,
              %{
                "display_name" => name,
                "editing_display_name" => false,
                "profile_error" => nil,
                "profile_notice" => "display_name_updated"
              },
              "ok"
            )

          {:error, changeset} ->
            put_world_state(
              socket,
              %{"profile_error" => inspect(changeset.errors)},
              "error:display_name_save_failed"
            )
        end
    end
  end

  @doc "Bind a Feishu open_id to a local entity URI."
  @spec bind_feishu_user(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def bind_feishu_user(socket, open_id, user_uri) do
    open_id = String.trim(open_id)
    user_uri = String.trim(user_uri)
    caller = socket.assigns.current_entity_uri
    workspace = socket.assigns.current_workspace_uri

    cond do
      open_id == "" or user_uri == "" ->
        put_feishu_bindings(socket, "error:binding_fields_required")

      not valid_entity_uri?(caller, workspace, user_uri) ->
        put_feishu_bindings(socket, "error:invalid_entity_uri")

      true ->
        user_binding = Module.concat([EzagentPluginFeishu, UserBinding])
        binding_policy = Module.concat([EzagentPluginFeishu, BindingPolicy])
        bound_by = URI.to_string(caller)

        with true <- Code.ensure_loaded?(user_binding),
             {:ok, _row} <- apply(user_binding, :bind, [open_id, user_uri, bound_by]) do
          if Code.ensure_loaded?(binding_policy) and
               function_exported?(binding_policy, :apply, 2) do
            _ = apply(binding_policy, :apply, [user_uri, bound_by])
          end

          put_feishu_bindings(socket, "ok")
        else
          false -> put_feishu_bindings(socket, "error:feishu_binding_unavailable")
          {:error, reason} -> put_feishu_bindings(socket, "error:#{reason(reason)}")
          other -> put_feishu_bindings(socket, "error:#{reason(other)}")
        end
    end
  end

  @doc "Remove a Feishu open_id binding."
  @spec unbind_feishu_user(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def unbind_feishu_user(socket, open_id) when is_binary(open_id) do
    open_id = String.trim(open_id)
    user_binding = Module.concat([EzagentPluginFeishu, UserBinding])

    with true <- open_id != "",
         true <- Code.ensure_loaded?(user_binding),
         :ok <- apply(user_binding, :unbind, [open_id]) do
      put_feishu_bindings(socket, "ok")
    else
      false -> put_feishu_bindings(socket, "error:open_id_required")
      {:error, reason} -> put_feishu_bindings(socket, "error:#{reason(reason)}")
      other -> put_feishu_bindings(socket, "error:#{reason(other)}")
    end
  end

  @doc "Remove a member from the current workspace."
  @spec remove_workspace_member(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def remove_workspace_member(socket, member_uri) when is_binary(member_uri) do
    with %URI{scheme: "workspace"} = workspace_uri <- socket.assigns.current_workspace_uri,
         {:ok, %URI{scheme: "entity"} = member} <- Ezagent.URI.parse(String.trim(member_uri)),
         workspace_name <- Ezagent.URI.workspace_name!(workspace_uri),
         :ok <-
           Ezagent.Workspace.remove_member(workspace_name, member, %{
             caller: socket.assigns.current_entity_uri,
             authenticated_principal: socket.assigns.current_entity_uri,
             caps: Ezagent.World.PresenterCaps.load(socket)
           }) do
      members =
        case Ezagent.Workspace.Store.get_by_name(workspace_name) do
          %{members: members} -> Enum.map(members || [], &uri_string/1)
          _ -> []
        end

      put_world_state(socket, %{"members" => members}, "ok")
    else
      {:error, reason} ->
        put_world_state(
          socket,
          %{"workspace_error" => reason(reason)},
          "error:remove_member_failed"
        )

      _ ->
        put_world_state(socket, %{"workspace_error" => "bad_member_uri"}, "error:bad_member_uri")
    end
  end

  @doc "Query a KB Agent through its Behavior and the caller's real caps."
  @spec query_kb(Phoenix.LiveView.Socket.t(), String.t(), String.t(), integer()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def query_kb(socket, agent_uri, query, k) do
    query = String.trim(query)

    with true <- query != "",
         {:ok, uri} <- kb_agent_uri(socket, agent_uri),
         {:ok, %{hits: hits}} <- dispatch_kb(socket, uri, :query, %{query: query, k: k}) do
      put_world_state(
        socket,
        %{"kb_hits" => hits, "kb_notice" => "query_complete", "kb_error" => nil},
        "ok"
      )
    else
      false ->
        put_world_state(socket, %{"kb_error" => "query_required"}, "error:query_required")

      {:error, reason} ->
        put_world_state(socket, %{"kb_error" => reason(reason)}, "error:kb_query_failed")
    end
  end

  @doc "Ingest a registered kb-source through the KB Behavior."
  @spec ingest_kb(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def ingest_kb(socket, agent_uri, source_uri) do
    source_uri = String.trim(source_uri)

    with true <- source_uri != "",
         {:ok, uri} <- kb_agent_uri(socket, agent_uri),
         {:ok, %{chunks: chunks}} <-
           dispatch_kb(socket, uri, :ingest, %{source_uri: source_uri}) do
      put_world_state(
        socket,
        %{"kb_notice" => "ingested:#{chunks}", "kb_error" => nil},
        "ok"
      )
    else
      false ->
        put_world_state(
          socket,
          %{"kb_error" => "source_uri_required"},
          "error:source_uri_required"
        )

      {:error, reason} ->
        put_world_state(socket, %{"kb_error" => reason(reason)}, "error:kb_ingest_failed")
    end
  end

  defp kb_agent_uri(socket, raw) do
    with {:ok, %URI{scheme: "entity"} = uri} <- Ezagent.URI.parse(String.trim(raw)),
         true <- Ezagent.URI.type?(uri, :agent),
         %URI{} = workspace_uri <- socket.assigns.current_workspace_uri,
         %URI{} = agent_workspace <- Ezagent.URI.entity_workspace_uri(uri),
         true <- uri_string(agent_workspace) == uri_string(workspace_uri) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_kb_agent}
    end
  end

  defp dispatch_kb(socket, agent_uri, action, args) do
    target = Ezagent.URI.with_action(agent_uri, :kb, action)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      origin: :authenticated_external,
      ctx: %{
        caller: socket.assigns.current_entity_uri,
        authenticated_principal: socket.assigns.current_entity_uri,
        caps: Ezagent.World.PresenterCaps.load(socket),
        reply: {:caller_inbox, self()}
      }
    })
  end

  @doc "Mint an invite for the current workspace through the CapBAC facade."
  @spec mint_workspace_invite(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def mint_workspace_invite(socket, args) do
    max_uses = integer_arg(args, "max_uses", 1)
    expires_in_hours = optional_integer_arg(args, "expires_in_hours")

    with %URI{scheme: "workspace"} = workspace_uri <- socket.assigns.current_workspace_uri,
         {:ok, %{invite: _invite}} <-
           Ezagent.Workspace.Invites.mint(
             workspace_uri,
             %{max_uses: max_uses, expires_in_hours: expires_in_hours},
             Ezagent.World.PresenterCaps.context(socket)
           ) do
      refresh_workspace_invites(socket, "invite_created")
    else
      {:error, reason} ->
        put_world_state(
          socket,
          %{"invite_error" => reason(reason), "invite_notice" => nil},
          "error:invite_create_failed"
        )

      _ ->
        put_world_state(
          socket,
          %{"invite_error" => "workspace_unavailable"},
          "error:no_workspace"
        )
    end
  end

  @doc "Revoke an invite for the current workspace through the CapBAC facade."
  @spec revoke_workspace_invite(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def revoke_workspace_invite(socket, code) do
    with %URI{scheme: "workspace"} = workspace_uri <- socket.assigns.current_workspace_uri,
         {:ok, %{invite: _invite}} <-
           Ezagent.Workspace.Invites.revoke(
             workspace_uri,
             String.trim(code),
             Ezagent.World.PresenterCaps.context(socket)
           ) do
      refresh_workspace_invites(socket, "invite_revoked")
    else
      {:error, reason} ->
        put_world_state(
          socket,
          %{"invite_error" => reason(reason), "invite_notice" => nil},
          "error:invite_revoke_failed"
        )

      _ ->
        put_world_state(
          socket,
          %{"invite_error" => "workspace_unavailable"},
          "error:no_workspace"
        )
    end
  end

  defp refresh_workspace_invites(socket, notice) do
    workspace_uri = socket.assigns.current_workspace_uri

    case Ezagent.Workspace.Invites.list(
           workspace_uri,
           Ezagent.World.PresenterCaps.context(socket)
         ) do
      {:ok, %{invites: invites}} ->
        put_world_state(
          socket,
          %{"invites" => invites, "invite_notice" => notice, "invite_error" => nil},
          "ok"
        )

      {:error, reason} ->
        put_world_state(socket, %{"invite_error" => reason(reason)}, "error:invite_list_failed")
    end
  end

  @doc "Create or update a SessionTemplate root version from the workspace template form."
  @spec save_session_template(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def save_session_template(socket, params) when is_map(params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()

    caller = socket.assigns.current_entity_uri
    # SECURITY (#165): thread the operator's REAL caps (mirroring
    # `remove_workspace_member`/`revoke_credential_grant`) so the domain-side
    # public-scope admin gate authorizes a `:public` socialware publish. Without
    # this the ctx carried no caps and a non-admin could publish a public def.
    caps = Ezagent.World.PresenterCaps.load(socket)

    with true <- name != "",
         %URI{scheme: "workspace"} = workspace_uri <- socket.assigns.current_workspace_uri,
         workspace_name <- Ezagent.URI.name!(workspace_uri),
         {:ok, socialware_definition} <- prepare_form_socialware(params),
         prepared_socialware_ref <- socialware_ref(socialware_definition),
         selected_socialware_refs <- socialware_refs(prepared_socialware_ref, params),
         {:ok, content} <-
           session_template_content(params, workspace_uri, prepared_socialware_ref),
         :ok <- authorize_template_save(workspace_uri, caller, caps, name, content),
         {:ok, _saved_socialware_ref} <-
           save_prepared_socialware(socialware_definition, workspace_uri, caller, caps),
         {:ok, template_uri} <-
           Ezagent.Entity.SessionTemplate.create(name, content,
             caller: caller,
             caps: caps,
             workspace: workspace_name
           ),
         :ok <- publish_current_template(workspace_uri, name, template_uri, caller) do
      put_world_state(
        socket,
        %{
          "session_templates" =>
            WorkspacePluginData.session_template_rows(caller, workspace_name),
          "template_notice" => "template_saved",
          "template_error" => nil,
          "last_template_uri" => uri_string(template_uri),
          "last_socialware_ref" => List.first(selected_socialware_refs),
          "last_socialware_refs" => selected_socialware_refs
        },
        "ok"
      )
      |> patch_to_workspaces()
    else
      false ->
        put_world_state(
          socket,
          %{"template_error" => "template_name_required"},
          "error:template_name_required"
        )

      {:error, reason} ->
        put_world_state(
          socket,
          %{"template_error" => reason(reason), "template_notice" => nil},
          "error:template_save_failed"
        )

      other ->
        put_world_state(
          socket,
          %{"template_error" => reason(other), "template_notice" => nil},
          "error:template_save_failed"
        )
    end
  end

  @doc "Set the credential default source shown on auto-derive detail."
  @spec set_default_source(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def set_default_source(socket, params) when is_map(params) do
    result =
      CredentialCascade.set_default_source(
        params,
        socket.assigns.current_entity_uri,
        Ezagent.World.PresenterCaps.load(socket)
      )

    case result do
      {:ok, _} ->
        put_auto_notice(socket, "default_source_updated", "ok")

      :ok ->
        put_auto_notice(socket, "default_source_updated", "ok")

      {:error, reason} ->
        put_auto_notice(
          socket,
          "set_default_source_failed:#{reason(reason)}",
          "error:set_default_source_failed"
        )

      other ->
        put_auto_notice(
          socket,
          "set_default_source_failed:#{reason(other)}",
          "error:set_default_source_failed"
        )
    end
  rescue
    err ->
      put_auto_notice(
        socket,
        "set_default_source_failed:#{inspect(err)}",
        "error:set_default_source_failed"
      )
  end

  @doc "Revoke a credential grant from the auto-derive detail panel."
  @spec revoke_credential_grant(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def revoke_credential_grant(socket, agent_uri) when is_binary(agent_uri) do
    with {:ok, %URI{scheme: "entity"} = uri} <- Ezagent.URI.parse(String.trim(agent_uri)),
         true <- Ezagent.URI.type?(uri, :agent) do
      case CredentialCascade.revoke_grant(
             uri,
             socket.assigns.current_entity_uri,
             Ezagent.World.PresenterCaps.load(socket)
           ) do
        {:ok, _} ->
          put_auto_notice(socket, "grant_revoked", "ok")

        :ok ->
          put_auto_notice(socket, "grant_revoked", "ok")

        {:error, reason} ->
          put_auto_notice(
            socket,
            "grant_revoke_failed:#{reason(reason)}",
            "error:grant_revoke_failed"
          )

        other ->
          put_auto_notice(
            socket,
            "grant_revoke_failed:#{reason(other)}",
            "error:grant_revoke_failed"
          )
      end
    else
      _ -> put_auto_notice(socket, "grant_revoke_failed:bad_agent_uri", "error:bad_agent_uri")
    end
  end

  defp put_feishu_bindings(socket, status) do
    put_world_state(socket, %{"bindings" => WorkspacePluginData.list_feishu_bindings()}, status)
  end

  defp put_auto_notice(socket, notice, status) do
    put_world_state(socket, %{"auto_derive_notice" => notice}, status)
  end

  defp prepare_form_socialware(params) do
    case Map.get(params, "socialware") || Map.get(params, :socialware) do
      socialware when is_map(socialware) ->
        Ezagent.Socialware.DefinitionEditor.validate_definition(socialware, complete: true)

      _ ->
        {:ok, nil}
    end
  end

  defp save_prepared_socialware(nil, _workspace_uri, _caller, _caps), do: {:ok, nil}

  defp save_prepared_socialware(definition, %URI{} = workspace_uri, %URI{} = caller, caps) do
    case Ezagent.Socialware.DefinitionEditor.save_authored_definition(
           definition,
           workspace_uri,
           caller,
           complete: true,
           caps: caps
         ) do
      {:ok, saved, _object} -> {:ok, saved.name}
      {:error, _} = error -> error
    end
  end

  defp socialware_ref(%Ezagent.Socialware.Definition{name: name}), do: name
  defp socialware_ref(nil), do: nil

  defp socialware_refs(ref, _params) when is_binary(ref) and ref != "", do: [ref]
  defp socialware_refs(_ref, params), do: authored_socialware_refs(params)

  defp authored_socialware_refs(params) when is_map(params) do
    params
    |> Map.get("installs", Map.get(params, :installs, []))
    |> case do
      installs when is_list(installs) ->
        installs |> Enum.map(&install_ref/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
    |> Enum.reject(&(&1 in @foundation_socialware_refs))
  end

  defp install_ref(ref) when is_binary(ref), do: ref
  defp install_ref(%{"ref" => ref}) when is_binary(ref), do: ref
  defp install_ref(%{ref: ref}) when is_binary(ref), do: ref
  defp install_ref(_), do: nil

  defp session_template_content(params, %URI{} = workspace_uri, socialware_ref) do
    params
    |> ensure_world_default_installs(socialware_ref)
    |> Map.put("default_workspace_uri", workspace_uri)
    |> Ezagent.Socialware.DefinitionEditor.composition_template_content(
      nil,
      workspace_uri,
      socialware_ref
    )
  end

  defp ensure_world_default_installs(params, socialware_ref)
       when is_binary(socialware_ref) and socialware_ref != "",
       do: params

  defp ensure_world_default_installs(params, _socialware_ref) when is_map(params) do
    case Map.get(params, "installs", Map.get(params, :installs)) do
      installs when is_list(installs) and installs != [] ->
        params

      _ ->
        Map.put(params, "installs", @default_world_template_installs)
    end
  end

  defp publish_current_template(
         %URI{} = workspace_uri,
         name,
         %URI{} = template_uri,
         %URI{} = caller
       )
       when is_binary(name) do
    Ezagent.TemplateTags.put(workspace_uri, name, "current", template_hash!(template_uri), caller)
  end

  defp template_hash!(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.last()
  end

  defp authorize_template_save(
         %URI{} = workspace_uri,
         %URI{} = caller,
         caps,
         name,
         content
       ) do
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :add_template)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{name: name, template: content},
           ctx: %{
             caller: caller,
             authenticated_principal: caller,
             caps: MapSet.new(caps),
             reply: :ignore
           },
           origin: :authenticated_external
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp integer_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp optional_integer_arg(args, key) do
    case Map.get(args, key) do
      nil -> nil
      "" -> nil
      value -> integer_arg(%{key => value}, key, nil)
    end
  end

  defp put_world_state(socket, updates, status) do
    state = Map.merge(socket.assigns.world_state, updates)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, status)
     |> push_event("world:state", updates)}
  end

  defp patch_to_workspaces({:noreply, socket}) do
    {:noreply, push_patch(socket, to: "/workspaces")}
  end

  defp valid_entity_uri?(caller, workspace, user_uri) do
    uri_options = Module.concat([Ezagent.UI, UriOptions])

    Code.ensure_loaded?(uri_options) and
      function_exported?(uri_options, :valid_for?, 4) and
      apply(uri_options, :valid_for?, [caller, workspace, user_uri, [:entity]])
  end

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
end
