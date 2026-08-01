defmodule Ezagent.CapabilityProtocolTest do
  use ExUnit.Case, async: true

  alias Ezagent.Cap.GrantArtifact
  alias Ezagent.Capability

  test "capability requests have no protocol version and may omit a grant id" do
    request = capability_request()
    protocol_version_field = String.to_atom("signing" <> "_version")

    refute Map.has_key?(request, protocol_version_field)
    assert request.grant_id == nil
    assert {:error, :missing_grant_id} = GrantArtifact.validate(request)
  end

  test "the sole issued-artifact wire shape round-trips grant identity" do
    request = capability_request()

    artifact = %{
      request
      | grant_id: Ecto.UUID.generate(),
        signature: <<1, 2, 3>>,
        key_id: "kind-g1:test-key",
        grantee_uri: Ezagent.URI.new!("entity://team-alpha/user/alice")
    }

    wire = Capability.to_map(artifact)
    json = artifact |> Jason.encode!() |> Jason.decode!()
    protocol_version_field = "signing" <> "_version"

    assert {:ok, decoded} = GrantArtifact.from_map(wire)
    assert decoded == artifact
    assert wire["grant_id"] == artifact.grant_id
    assert json["grant_id"] == artifact.grant_id
    refute Map.has_key?(wire, protocol_version_field)
    refute Map.has_key?(json, protocol_version_field)
    assert Capability.identity_key(decoded) == Capability.identity_key(request)
  end

  test "request decode does not invent a protocol version or grant identity" do
    wire = capability_request() |> Capability.to_map() |> Map.delete("grant_id")
    decoded = Capability.from_map(wire)
    protocol_version_field = String.to_atom("signing" <> "_version")

    refute Map.has_key?(decoded, protocol_version_field)
    assert decoded.grant_id == nil
  end

  defp capability_request do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.new!("session://team-alpha/default/chat"),
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: Ezagent.URI.new!("entity://team-alpha/user/issuer"),
      granted_at: ~U[2026-08-01 00:00:00Z]
    }
  end
end
