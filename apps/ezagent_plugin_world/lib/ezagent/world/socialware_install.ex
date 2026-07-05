defmodule Ezagent.World.SocialwareInstall do
  @moduledoc """
  Creates the transient session template used when the sessions page installs a
  socialware manifest.

  The source definition stays read-only in its owner workspace. Installing writes
  a local template in the caller's workspace whose content points at the selected
  definition name; the normal session-create path then consumes that local
  template.
  """

  @typedoc """
  Optional revision identity for a content-hash-addressed install (P1 §O-1). When
  present, the install pins the EXACT `config_id` revision (scope-gated) instead
  of resolving the bare `ref` name. `content_hash`, when set, is verified against
  the resolved revision.
  """
  @type revision :: %{
          required(:config_id) => String.t(),
          optional(:content_hash) => String.t() | nil
        }

  @type install_config :: map()

  @doc """
  Return the template name that should be used for `session.create`.

  With no socialware ref, the caller-supplied `template_name` is returned. With a
  ref, this validates that the definition is visible/installable from the caller's
  workspace, writes a local install template, tags it `current`, and returns that
  local template name.

  With a `revision` (`%{config_id: ...}`, P1 §O-1), the install is
  content-hash-addressed: it pins the EXACT revision `config_id` names — resolved
  through the scope-gated `DefinitionRegistry.resolve_installable_revision/3` (so
  a foreign PUBLIC catalog card installs THAT revision, never a same-named local
  def, and a PRIVATE foreign def can NOT be installed by supplying its
  `config_id`). Without a revision the legacy bare-name path is unchanged.
  """
  @spec prepare_create_template(
          URI.t(),
          URI.t(),
          String.t(),
          String.t() | nil,
          revision() | nil,
          install_config()
        ) :: {:ok, String.t()} | {:error, term()}
  def prepare_create_template(
        workspace_uri,
        caller,
        template_name,
        ref,
        revision \\ nil,
        install_config \\ %{}
      )

  def prepare_create_template(_workspace_uri, _caller, template_name, ref, _revision, _config)
      when ref in [nil, ""] do
    {:ok, template_name}
  end

  def prepare_create_template(
        %URI{} = workspace_uri,
        %URI{} = caller,
        template_name,
        ref,
        revision,
        install_config
      )
      when is_binary(ref) do
    ref = String.trim(ref)

    if ref == "" do
      {:ok, template_name}
    else
      template_name = "socialware-install-#{sanitize_template_name(ref)}"

      with {:ok, install_entry} <- resolve_install_entry(workspace_uri, ref, revision),
           {:ok, install_entry} <- put_install_config(install_entry, install_config),
           {:ok, template_uri} <-
             persist_install_template(workspace_uri, caller, template_name, install_entry),
           :ok <- publish_current_template(workspace_uri, template_name, template_uri, caller) do
        {:ok, template_name}
      end
    end
  end

  def prepare_create_template(_workspace_uri, _caller, _template_name, _ref, _revision, _config),
    do: {:error, :invalid_socialware_ref}

  # Content-hash-addressed install (P1 §O-1): a revision identity resolves the
  # EXACT immutable revision by its `config_id` through the scope-gated
  # `resolve_installable_revision/3`, then bakes the pin (`config_id` +
  # `content_hash`) into a MAP install entry. `Installation` freeze-pin honors it
  # via `fetch_object/1`. Without a revision → the legacy bare-name entry.
  defp resolve_install_entry(%URI{} = workspace_uri, _ref, %{config_id: config_id} = revision)
       when is_binary(config_id) and config_id != "" do
    expected_hash = Map.get(revision, :content_hash)

    case Ezagent.Socialware.DefinitionRegistry.resolve_installable_revision(
           workspace_uri,
           config_id,
           expected_hash
         ) do
      {:ok, definition, object} ->
        {:ok, %{ref: definition.name, config_id: object.id, content_hash: object.content_hash}}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_install_entry(%URI{} = workspace_uri, ref, _revision) do
    case lookup_installable_socialware(workspace_uri, ref) do
      {:ok, _definition, _object} -> {:ok, ref}
      {:error, _} = error -> error
    end
  end

  defp lookup_installable_socialware(%URI{} = workspace_uri, ref) when is_binary(ref) do
    case Ezagent.Socialware.DefinitionRegistry.lookup(workspace_uri, ref) do
      {:ok, definition, object} -> {:ok, definition, object}
      :error -> {:error, {:unknown_socialware_install, ref}}
    end
  end

  defp put_install_config(install_entry, config) when config in [%{}, nil], do: {:ok, install_entry}

  defp put_install_config(install_entry, config) when is_map(config) do
    normalized = normalize_install_config(config)

    entry =
      case install_entry do
        ref when is_binary(ref) -> %{ref: ref, config: normalized}
        %{} = map -> Map.put(map, :config, normalized)
      end

    {:ok, entry}
  end

  defp put_install_config(_install_entry, config), do: {:error, {:invalid_install_config, config}}

  defp normalize_install_config(config) do
    case Map.get(config, :role_slots) || Map.get(config, "role_slots") do
      role_slots when is_list(role_slots) -> %{"role_slots" => role_slots}
      _ -> %{}
    end
  end

  defp persist_install_template(%URI{} = workspace_uri, %URI{} = caller, name, install_entry) do
    workspace = Ezagent.URI.workspace_name!(workspace_uri)

    content = %{
      description: "Install #{install_ref(install_entry)}",
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      installs: [install_entry]
    }

    Ezagent.Entity.SessionTemplate.create(name, content,
      caller: caller,
      caps: [session_template_write_cap(workspace_uri, caller)],
      workspace: workspace
    )
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

  defp session_template_write_cap(%URI{} = workspace_uri, %URI{} = caller) do
    cap =
      Ezagent.Capability.cap(
        :session_template,
        Ezagent.ActionSet.Template,
        :any,
        {:within_workspace, workspace_uri},
        workspace_uri
      )

    %Ezagent.Capability{cap | granted_by: caller, granted_at: DateTime.utc_now()}
  end

  defp install_ref(ref) when is_binary(ref), do: ref
  defp install_ref(%{ref: ref}), do: ref

  defp sanitize_template_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._~-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "manifest"
      safe -> safe
    end
  end
end
