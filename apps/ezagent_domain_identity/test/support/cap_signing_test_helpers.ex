defmodule EzagentDomainIdentity.CapSigningTestHelpers do
  @moduledoc false

  alias Ezagent.{Cap, Capability, Users}
  alias EzagentCore.Repo

  def issue!(receiver, %Capability{} = proposal, authorization \\ :from_provenance) do
    receiver = parse_uri(receiver)
    authorization = resolve_authorization(authorization, proposal)

    case Cap.issue(authorization, receiver, proposal) do
      {:ok, artifact} -> artifact
      {:error, reason} -> raise "test cap issuance failed: #{inspect(reason)}"
    end
  end

  def issue_all!(receiver, caps), do: Enum.map(caps, &issue!(receiver, &1))

  def create_legacy_user!(uri, password, caps, opts \\ []) do
    {:ok, _user} = Users.create(uri, password, [], opts)
    :ok = put_legacy_caps!(uri, caps)
    Users.get_by_uri(uri)
  end

  def put_legacy_caps!(uri, caps) do
    uri_string = uri |> parse_uri() |> URI.to_string()
    row = Repo.get_by!(Users, uri: uri_string)

    caps_json =
      caps
      |> Enum.map(&Capability.to_map/1)
      |> Jason.encode!()

    row
    |> Ecto.Changeset.change(%{caps_json: caps_json})
    |> Repo.update!()

    :ok
  end

  defp resolve_authorization(:from_provenance, %Capability{granted_by: %URI{} = issuer}),
    do: {:genesis, issuer}

  defp resolve_authorization(authorization, _proposal), do: authorization

  defp parse_uri(%URI{} = uri), do: uri
  defp parse_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
end
