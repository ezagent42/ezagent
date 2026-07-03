defmodule Ezagent.World.SocialwareInstall do
  @moduledoc """
  Creates the transient session template used when the sessions page installs a
  socialware manifest.

  The source definition stays read-only in its owner workspace. Installing writes
  a local template in the caller's workspace whose content points at the selected
  definition name; the normal session-create path then consumes that local
  template.
  """

  @doc """
  Return the template name that should be used for `session.create`.

  With no socialware ref, the caller-supplied `template_name` is returned. With a
  ref, this validates that the definition is visible/installable from the caller's
  workspace, writes a local install template, tags it `current`, and returns that
  local template name.
  """
  @spec prepare_create_template(URI.t(), URI.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def prepare_create_template(_workspace_uri, _caller, template_name, ref)
      when ref in [nil, ""] do
    {:ok, template_name}
  end

  def prepare_create_template(%URI{} = workspace_uri, %URI{} = caller, template_name, ref)
      when is_binary(ref) do
    ref = String.trim(ref)

    if ref == "" do
      {:ok, template_name}
    else
      template_name = "socialware-install-#{sanitize_template_name(ref)}"

      with {:ok, _definition, _object} <- lookup_installable_socialware(workspace_uri, ref),
           {:ok, template_uri} <-
             persist_install_template(workspace_uri, caller, template_name, ref),
           :ok <- publish_current_template(workspace_uri, template_name, template_uri, caller) do
        {:ok, template_name}
      end
    end
  end

  def prepare_create_template(_workspace_uri, _caller, _template_name, _ref),
    do: {:error, :invalid_socialware_ref}

  defp lookup_installable_socialware(%URI{} = workspace_uri, ref) when is_binary(ref) do
    case Ezagent.Socialware.DefinitionRegistry.lookup(workspace_uri, ref) do
      {:ok, definition, object} -> {:ok, definition, object}
      :error -> {:error, {:unknown_socialware_install, ref}}
    end
  end

  defp persist_install_template(%URI{} = workspace_uri, %URI{} = caller, name, ref) do
    workspace = Ezagent.URI.workspace_name!(workspace_uri)

    content = %{
      description: "Install #{ref}",
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      installs: [ref]
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
