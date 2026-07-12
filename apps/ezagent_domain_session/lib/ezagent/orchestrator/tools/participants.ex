defmodule Ezagent.Orchestrator.Tools.Participants do
  @moduledoc false

  alias Ezagent.Orchestrator.Tools

  @doc false
  @spec add_participant(String.t() | URI.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def add_participant(ref, role_name, opts \\ []) when is_binary(role_name) do
    with {:ok, caller} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- Tools.require_opt(opts, :session_uri),
         :ok <- Tools.preflight_within_session_cap(caps, session_uri, :join) do
      add_participant_ref(ref, role_name, caller, caps, workspace_uri, session_uri, opts)
    end
  end

  defp add_participant_ref(
         %URI{scheme: "entity"} = member_uri,
         role_name,
         caller,
         caps,
         _workspace_uri,
         session_uri,
         _opts
       ) do
    admit_participant(session_uri, member_uri, %{role_name: role_name}, caller, caps, false)
  end

  defp add_participant_ref(
         %URI{scheme: "template"} = source_template_uri,
         role_name,
         _caller,
         _caps,
         _workspace_uri,
         _session_uri,
         opts
       ) do
    in_session_template = Keyword.get(opts, :in_session_template, true)
    Tools.add_managed_member(source_template_uri, role_name, in_session_template, opts)
  end

  defp add_participant_ref(
         ref,
         role_name,
         caller,
         caps,
         workspace_uri,
         session_uri,
         opts
       )
       when is_binary(ref) do
    case parse_ref_uri(ref) do
      {:ok, %URI{} = uri} ->
        add_participant_ref(uri, role_name, caller, caps, workspace_uri, session_uri, opts)

      :error ->
        add_manifest_participant(ref, role_name, caller, caps, workspace_uri, session_uri, opts)
    end
  end

  defp add_participant_ref(ref, _role_name, _caller, _caps, _workspace_uri, _session_uri, _opts),
    do: {:error, {:invalid_participant_ref, ref}}

  defp admit_participant(session_uri, member_uri, facets, caller, caps, fresh_spawn?) do
    with :ok <-
           Ezagent.ActionSet.Session.Membership.provision_invited_join_authority(
             session_uri,
             member_uri,
             caller
           ) do
      case Tools.join_member(session_uri, member_uri, facets, caller, caps) do
        :ok ->
          :ok =
            Ezagent.ActionSet.Session.Membership.mount_participation_caps(session_uri, member_uri)

          {:ok, member_uri}

        {:error, reason} ->
          if fresh_spawn?, do: _ = Tools.terminate_worker(member_uri, caller, caps)
          {:error, reason}
      end
    end
  end

  defp add_manifest_participant(ref, role_name, caller, caps, workspace_uri, session_uri, opts) do
    with {:ok, body} <- File.read(ref),
         {:ok, manifest} <- Ezagent.AgentManifest.load(body),
         {:ok, member_uri, fresh?} <-
           spawn_manifest_participant(
             manifest,
             Keyword.get(opts, :slots, %{}),
             role_name,
             caller,
             caps,
             workspace_uri,
             session_uri
           ) do
      facets = %{
        role_name: role_name,
        in_session_template: Keyword.get(opts, :in_session_template, true)
      }

      admit_participant(session_uri, member_uri, facets, caller, caps, fresh?)
    else
      {:error, _} = err -> err
      {:error, reason, _path} -> {:error, {:participant_manifest_read_failed, reason}}
    end
  end

  defp spawn_manifest_participant(
         %Ezagent.AgentManifest{} = manifest,
         slots,
         role_name,
         caller,
         caps,
         workspace_uri,
         session_uri
       ) do
    member_uri = manifest_member_uri(manifest, role_name, workspace_uri, session_uri)

    case Ezagent.Entity.Agent.spawn_from_manifest(
           manifest,
           slots,
           member_uri,
           caller,
           workspace_uri,
           caller: caller,
           caps: caps
         ) do
      {:ok, %{workers: [%URI{} = ^member_uri | _], fresh?: fresh?}} ->
        {:ok, member_uri, fresh?}

      {:ok, %{workers: [%URI{} = worker_uri | _], fresh?: fresh?}} ->
        {:ok, worker_uri, fresh?}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_manifest_spawn_result, other}}
    end
  end

  defp manifest_member_uri(manifest, role_name, workspace_uri, session_uri) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    slug =
      "#{manifest.name}-#{role_name}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")

    digest =
      :erlang.phash2({URI.to_string(session_uri), role_name, manifest.name})
      |> Integer.to_string(36)

    Ezagent.URI.agent(workspace_name, "#{slug}-#{digest}")
  end

  defp parse_ref_uri(ref) do
    {:ok, Ezagent.URI.new!(ref)}
  rescue
    ArgumentError -> :error
  end
end
