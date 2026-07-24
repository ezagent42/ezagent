defmodule Ezagent.Orchestrator.Tools.Templates do
  @moduledoc false

  require Logger

  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Socialware.DefinitionEditor
  alias Ezagent.TemplateTags

  @spec update_template(keyword()) :: {:ok, URI.t()} | {:error, term()}
  def update_template(opts \\ []) do
    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         {:ok, %URI{} = parent_uri} <- require_opt(opts, :parent_template_uri),
         :ok <- check_template_write_cap(caps, workspace_uri, caller_uri),
         :ok <- check_parent_alive(parent_uri),
         {:ok, parent_name} <- extract_template_name(parent_uri),
         {:ok, _definition, _object} <-
           DefinitionEditor.snapshot_live_session(session_uri, workspace_uri, caller_uri,
             caps: caps
           ),
         {:ok, slice} <- build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri) do
      content =
        slice
        |> Map.put(:name, parent_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())

      with {:ok, new_uri} <-
             SessionTemplate.persist_version(content, workspace_uri,
               caller: caller_uri,
               caps: caps
             ),
           :ok <- publish_current(workspace_uri, parent_name, new_uri, caller_uri) do
        {:ok, new_uri}
      end
    end
  end

  @spec save_template_as(String.t(), keyword()) :: {:ok, URI.t()} | {:error, term()}
  def save_template_as(new_name, opts \\ []) when is_binary(new_name) and new_name != "" do
    parent_uri =
      case Keyword.get(opts, :parent_template_uri) do
        %URI{} = u -> u
        _ -> nil
      end

    with {:ok, session_uri} <- require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- require_opt(opts, :caller),
         {:ok, caps} <- require_opt(opts, :caps),
         :ok <- check_template_write_cap(caps, workspace_uri, caller_uri),
         {:ok, _definition, _object} <-
           DefinitionEditor.snapshot_live_session(session_uri, workspace_uri, caller_uri,
             name: new_name,
             caps: caps
           ),
         {:ok, slice} <-
           build_working_copy(session_uri, workspace_uri, caller_uri, parent_uri, new_name) do
      content =
        slice
        |> Map.put(:name, new_name)
        |> Map.put(:created_by, caller_uri)
        |> Map.put(:created_at, DateTime.utc_now())
        |> maybe_put_seed_surface(session_uri)

      case SessionTemplate.persist_version(content, workspace_uri,
             caller: caller_uri,
             caps: caps
           ) do
        {:ok, new_uri} ->
          :ok = publish_current(workspace_uri, new_name, new_uri, caller_uri)
          owner_uri = Keyword.get(opts, :owner, caller_uri)
          :ok = grant_owner_template_cap(owner_uri, new_uri, workspace_uri)
          {:ok, new_uri}

        {:error, _} = err ->
          err
      end
    end
  end

  @spec list_templates(String.t() | nil, keyword()) ::
          {:ok, %{agent_templates: [URI.t()], session_templates: [URI.t()]}}
          | {:error, term()}
  def list_templates(name_filter \\ nil, opts \\ []) do
    with {:ok, caps} <- require_opt(opts, :caps),
         {:ok, workspace_uri} <- require_opt(opts, :workspace_uri),
         {:ok, caller} <- require_opt(opts, :caller) do
      agent_allowed? =
        Ezagent.Session.Config.Admission.template_cap?(
          caps,
          :agent_template,
          workspace_uri,
          caller
        )

      session_allowed? =
        Ezagent.Session.Config.Admission.template_cap?(
          caps,
          :session_template,
          workspace_uri,
          caller
        )

      if not agent_allowed? and not session_allowed? do
        {:error, :unauthorized}
      else
        rows = snapshot_rows_in_workspace(workspace_uri)

        agents =
          if agent_allowed?,
            do: filter_rows(rows, "agent_template", "agent", name_filter),
            else: []

        sessions =
          if session_allowed?,
            do: filter_rows(rows, "session_template", "session", name_filter),
            else: []

        {:ok, %{agent_templates: agents, session_templates: sessions}}
      end
    end
  end

  defp check_parent_alive(%URI{} = parent_uri) do
    cond do
      Ezagent.Kind.alive?(parent_uri) ->
        :ok

      durable_snapshot_exists?(parent_uri) ->
        :ok

      true ->
        {:error, :parent_template_deleted}
    end
  end

  defp publish_current(%URI{} = workspace_uri, template_name, %URI{} = template_uri, caller_uri)
       when is_binary(template_name) do
    TemplateTags.put(
      workspace_uri,
      template_name,
      "current",
      template_hash!(template_uri),
      caller_uri
    )
  end

  # Capture the session's CURRENT approved Surface page + theme into the template
  # content as `seed_surface`, so a session created from this template renders the
  # same page (see `Ezagent.Session.SurfaceSeed`). Core-only (reads the `:surface`
  # slice via `Ezagent.Kind.get_slice`); a session with no surface / no approved
  # version is left untouched. Never carries conversation history.
  defp maybe_put_seed_surface(content, %URI{} = session_uri) do
    case capture_seed_surface(session_uri) do
      %{} = seed -> Map.put(content, :seed_surface, seed)
      _ -> content
    end
  end

  defp capture_seed_surface(session_uri) do
    with {:ok, slice} when is_map(slice) <- Ezagent.Kind.get_slice(session_uri, :surface),
         approved when not is_nil(approved) <-
           Map.get(slice, :approved) || Map.get(slice, "approved"),
         versions when is_map(versions) <- Map.get(slice, :versions) || Map.get(slice, "versions"),
         %{} = version <- Map.get(versions, approved),
         tree when is_map(tree) <- Map.get(version, :tree) || Map.get(version, "tree") do
      %{
        tree: tree,
        shell: Map.get(slice, :shell) || Map.get(slice, "shell") || "",
        shell_css: Map.get(slice, :shell_css) || Map.get(slice, "shell_css") || ""
      }
    else
      _ -> nil
    end
  end

  defp template_hash!(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.last()
  end

  defp durable_snapshot_exists?(%URI{} = uri) do
    case Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri)) do
      %Ezagent.Ecto.KindSnapshot{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  defp grant_owner_template_cap(
         %URI{} = owner_uri,
         %URI{} = new_template_uri,
         %URI{} = _workspace_uri
       ) do
    with :ok <- Ezagent.Identity.TargetAuthority.ensure(owner_uri, new_template_uri) do
      Ezagent.CapabilityRegistry.subjects_for_kind(Ezagent.Entity.SessionTemplate)
      |> Enum.reduce_while(:ok, fn subject, :ok ->
        requested =
          Ezagent.Capability.cap(
            :session_template,
            subject.behavior,
            subject.action,
            new_template_uri,
            Ezagent.Capability.workspace_of(new_template_uri)
          )

        authorization =
          if Ezagent.URI.stable_key(owner_uri) ==
               Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri()),
             do: {:admin, owner_uri},
             else: {:held_by, owner_uri}

        with :ok <-
               Ezagent.Identity.Grant.grant_cap(
                 owner_uri,
                 requested,
                 authorization
               ) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
    |> case do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "save_template_as: owner template-cap grant failed: #{inspect(other)} — " <>
            "template persisted; owner may need a re-grant to instantiate it"
        )

        :ok
    end
  end

  defp snapshot_rows_in_workspace(%URI{} = workspace_uri) do
    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
  rescue
    _ -> []
  end

  defp filter_rows(rows, kind_type, expected_host, name_filter) do
    rows
    |> Enum.filter(fn row -> row.kind_type == kind_type end)
    |> Enum.map(fn row -> Ezagent.URI.new!(row.uri) end)
    |> Enum.filter(&template_match?(&1, expected_host, name_filter))
    |> Enum.sort_by(&URI.to_string/1)
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_opt, key}}
      v -> {:ok, v}
    end
  end

  defp check_template_write_cap(caps, %URI{} = workspace_uri, %URI{} = caller) do
    if Ezagent.Session.Config.Admission.template_write_cap?(caps, workspace_uri, caller) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp template_match?(%URI{scheme: "template"} = uri, expected_host, nil) do
    Ezagent.URI.type?(uri, expected_host) and match?({:ok, _name}, Ezagent.URI.name(uri))
  end

  defp template_match?(
         %URI{scheme: "template"} = uri,
         expected_host,
         filter
       )
       when is_binary(filter) do
    template_match?(uri, expected_host, nil) and
      uri |> Ezagent.URI.name!() |> String.contains?(filter)
  end

  defp template_match?(_, _, _), do: false

  defp extract_template_name(%URI{scheme: "template"} = uri) do
    if not Ezagent.URI.type?(uri, :session) do
      {:error, {:not_a_session_template_uri, uri}}
    else
      case Ezagent.URI.name(uri) do
        {:ok, name_with_hash} ->
          name = name_with_hash |> String.split("@") |> hd()

          if name == "" do
            {:error, :template_name_empty}
          else
            {:ok, name}
          end

        _ ->
          {:error, :template_name_empty}
      end
    end
  end

  defp extract_template_name(other), do: {:error, {:not_a_session_template_uri, other}}

  defp read_chat_slice(%URI{} = session_uri) do
    case Ezagent.Kind.get_raw_slice(session_uri, :session) do
      {:ok, chat_slice} ->
        Map.get(chat_slice, :state, chat_slice)

      {:error, _} ->
        %{}
    end
  end

  defp build_working_copy(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = _caller_uri,
         parent_uri,
         install_ref \\ nil
       ) do
    slice = read_chat_slice(session_uri)

    content = %{
      description: Map.get(slice, :description, ""),
      default_workspace_uri: workspace_uri,
      parent_template_uri: parent_uri,
      installs:
        session_uri
        |> Ezagent.Entity.Session.read_template_working_copy()
        |> Map.get(:session_template_uri)
        |> template_installs_or_default(install_ref)
    }

    {:ok, content}
  end

  defp template_installs_or_default(_template_uri, install_ref)
       when is_binary(install_ref) and install_ref != "",
       do: [install_ref]

  defp template_installs_or_default(%URI{} = template_uri, _install_ref) do
    with {:ok, _pid} <- Ezagent.Entity.Session.ensure_template_alive(template_uri),
         {:ok, content} <- Ezagent.Entity.Session.read_template_content(template_uri) do
      Ezagent.Socialware.Installation.installs_from_template(content)
    else
      _ -> Ezagent.Socialware.Installation.default_installs()
    end
  end

  defp template_installs_or_default(_template_uri, _install_ref),
    do: Ezagent.Socialware.Installation.default_installs()
end
