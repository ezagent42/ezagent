defmodule Ezagent.World.CredentialCascade do
  @moduledoc """
  JSON-safe credential cascade read/action helpers for the world auto-derive
  detail surface.
  """

  alias Ezagent.Credential.{GrantRow, UserDefaultSource}
  alias Ezagent.Invocation

  @doc "Build the credential cascade panel state for an auto-derived agent detail."
  @spec detail_for(URI.t(), map()) :: map() | nil
  def detail_for(%URI{} = agent_uri, detail) when is_map(detail) do
    case Ezagent.URI.type(agent_uri) do
      {:ok, "agent"} ->
        slices = Map.get(detail, :slices, %{})
        sandbox = slices |> slice(:sandbox) |> slice_state()
        respawn_data = map_field(sandbox, :respawn_template_data) || %{}
        resolution = map_field(respawn_data, :cascade_resolution) || %{}
        grant = GrantRow.get_for_agent(URI.to_string(agent_uri))
        flavor = string_field(respawn_data, :flavor) || "cc"
        owner_uri = string_field(resolution, :owner_uri)
        workspace_uri = string_field(resolution, :workspace_uri)
        source_uri = grant_source(grant) || string_field(resolution, :credential_source_uri)

        %{
          "agent_uri" => jsonable(agent_uri),
          "flavor" => flavor,
          "owner_uri" => owner_uri,
          "workspace_uri" => workspace_uri,
          "credential_source_uri" => source_uri,
          "default_source_uri" => default_source(owner_uri, workspace_uri, flavor),
          "layer_stack" => layer_stack(resolution),
          "config_view" => config_view(sandbox, respawn_data),
          "grant" => grant_view(grant),
          "form" => form_defaults(owner_uri, workspace_uri, flavor, source_uri)
        }

      _ ->
        nil
    end
  end

  def detail_for(_agent_uri, _detail), do: nil

  @doc "Set the selected default credential source through the domain dispatch path."
  @spec set_default_source(map(), URI.t() | nil, Enumerable.t()) :: term()
  def set_default_source(params, caller_uri, caller_caps) when is_map(params) do
    owner_uri = Map.fetch!(params, "owner_uri")

    UserDefaultSource.set_via_dispatch(
      owner_uri,
      %{
        flavor: Map.fetch!(params, "flavor"),
        source_uri: Map.fetch!(params, "source_uri"),
        workspace: workspace_name(Map.fetch!(params, "workspace_uri"))
      },
      %{caller: caller_uri, caps: caller_caps}
    )
  end

  @doc "Revoke the current credential grant for an agent through its action."
  @spec revoke_grant(URI.t(), URI.t() | nil, Enumerable.t()) :: term()
  def revoke_grant(%URI{} = agent_uri, caller_uri, caller_caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(agent_uri, :credential_grant, :revoke_credential_grant),
      mode: :call,
      args: %{},
      ctx: %{caller: caller_uri, caps: caller_caps, reply: :sync},
      origin: :authenticated_external
    })
  end

  defp layer_stack(resolution) do
    [
      %{"level" => "flavor-base", "source" => string_field(resolution, :flavor_base_uri)},
      %{"level" => "workspace", "source" => string_field(resolution, :workspace_layer_uri)},
      %{"level" => "user", "source" => string_field(resolution, :owner_uri)},
      %{"level" => "session", "source" => string_field(resolution, :session_uri)}
    ]
  end

  defp config_view(sandbox, respawn_data) do
    %{
      "config_dir_path" => string_field(sandbox, :config_dir_path),
      "template_class" => inspect(map_field(sandbox, :template_class)),
      "respawn_template_data" => jsonable(respawn_data)
    }
  end

  defp grant_view(nil), do: nil

  defp grant_view(%GrantRow{} = row) do
    %{
      "agent_uri" => row.agent_uri,
      "credential_source_uri" => row.credential_source_uri,
      "approved_by" => row.approved_by,
      "version" => row.version,
      "status" => if(row.revoked_at, do: "revoked", else: "active"),
      "revoked_at" => datetime(row.revoked_at)
    }
  end

  defp form_defaults(nil, workspace_uri, flavor, source_uri) do
    form_defaults("", workspace_uri, flavor, source_uri)
  end

  defp form_defaults(owner_uri, workspace_uri, flavor, source_uri) do
    %{
      "owner_uri" => owner_uri || "",
      "workspace_uri" => workspace_uri || "",
      "flavor" => flavor || "",
      "source_uri" => source_uri || ""
    }
  end

  defp default_source(nil, _workspace_uri, _flavor), do: nil
  defp default_source(_owner_uri, nil, _flavor), do: nil
  defp default_source(_owner_uri, _workspace_uri, nil), do: nil

  defp default_source(owner_uri, workspace_uri, flavor) do
    UserDefaultSource.resolve(owner_uri, workspace_name(workspace_uri), flavor)
  end

  defp grant_source(%GrantRow{credential_source_uri: source}), do: source
  defp grant_source(_), do: nil

  defp workspace_name(%URI{} = uri), do: Ezagent.URI.workspace_name!(uri)

  defp workspace_name(other) when is_binary(other) do
    case Ezagent.URI.parse(other) do
      {:ok, %URI{} = uri} -> Ezagent.URI.workspace_name!(uri)
      {:error, _} -> other
    end
  end

  defp workspace_name(other), do: other

  defp slice(slices, key), do: Map.get(slices, key) || Map.get(slices, Atom.to_string(key)) || %{}

  defp slice_state(slice) when is_map(slice), do: map_field(slice, :state) || slice
  defp slice_state(_), do: %{}

  defp map_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_field(_map, _key), do: nil

  defp string_field(map, key) do
    case map_field(map, key) do
      %URI{} = uri -> URI.to_string(uri)
      value when is_binary(value) -> value
      nil -> nil
      value -> inspect(value)
    end
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(other), do: inspect(other)

  defp jsonable(%URI{} = uri), do: URI.to_string(uri)
  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp jsonable(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.map(&jsonable/1)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

  defp jsonable(map) when is_map(map),
    do: map |> Map.new(fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other), do: other
end
