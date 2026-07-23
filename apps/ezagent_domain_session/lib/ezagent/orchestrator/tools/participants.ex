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
         :ok <- Tools.preflight_within_session_cap(caller, caps, session_uri, :join) do
      add_participant_ref(ref, role_name, caller, caps, workspace_uri, session_uri, opts)
    end
  end

  @doc """
  Import a participant manifest from a host-local, confined directory.

  This is deliberately separate from the remotely projectable
  `add_participant/3` operation. Callers must opt into the local boundary,
  hold explicit management authority over the addressed session, and supply
  the trusted manifest root. No HTTP/MCP/remote CLI projection calls this API.
  """
  @spec import_participant_manifest(String.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def import_participant_manifest(path, role_name, opts \\ [])
      when is_binary(path) and is_binary(role_name) do
    with true <- Keyword.get(opts, :local_operator, false),
         {:ok, caller} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, session_uri} <- Tools.require_opt(opts, :session_uri),
         {:ok, root} <- Tools.require_opt(opts, :manifest_root),
         :ok <- preflight_operator_cap(caller, caps, session_uri, workspace_uri),
         :ok <- Tools.preflight_within_session_cap(caller, caps, session_uri, :join),
         {:ok, body} <- Ezagent.Session.Config.ManifestImport.read(path, root),
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
      false -> {:error, :local_operator_required}
      {:error, _} = error -> error
    end
  end

  defp add_participant_ref(
         %URI{scheme: "entity"} = member_uri,
         role_name,
         caller,
         caps,
         _workspace_uri,
         session_uri,
         opts
       ) do
    facets = %{
      role_name: role_name,
      in_session_template: Keyword.get(opts, :in_session_template, true)
    }

    admit_participant(session_uri, member_uri, facets, caller, caps, false)
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
      {:ok, %URI{scheme: "entity"} = uri} ->
        add_participant_ref(uri, role_name, caller, caps, workspace_uri, session_uri, opts)

      _ ->
        {:error, {:invalid_participant_ref, :existing_entity_uri_required}}
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
          # D1 join 补发:participation tier + view caps + mount operate keys。
          :ok = Ezagent.Socialware.MemberBackfill.backfill(session_uri, member_uri)

          {:ok, member_uri}

        {:error, reason} ->
          if fresh_spawn?, do: _ = Tools.terminate_worker(member_uri, caller, caps)
          {:error, reason}
      end
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

    case Ezagent.Domain.Agent.materialize_from_manifest(
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

  defp preflight_operator_cap(holder, caps, session_uri, workspace_uri) do
    needed = %{
      kind: Ezagent.Entity.Session.type_name(),
      behavior: Ezagent.ActionSet.Manage,
      action: :reconfigure,
      instance: session_uri,
      workspace_uri: workspace_uri
    }

    if Ezagent.Capability.Authorization.authorizes?(holder, caps, needed),
      do: :ok,
      else: {:error, :operator_cap_required}
  end
end
