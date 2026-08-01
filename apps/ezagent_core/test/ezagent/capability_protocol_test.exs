defmodule Ezagent.CapabilityProtocolTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability

  test "legacy capability shape defaults to signing v1 without a grant id" do
    capability = legacy_capability()

    assert Map.fetch!(capability, :signing_version) == 1
    assert Map.fetch!(capability, :grant_id) == nil
  end

  test "v2 protocol fields round-trip without changing logical identity" do
    legacy = legacy_capability()
    v2 = %{legacy | signing_version: 2, grant_id: "grant-018fbc96"}

    wire = Capability.to_map(v2)
    decoded = Capability.from_map(wire)
    json = v2 |> Jason.encode!() |> Jason.decode!()

    assert wire["signing_version"] == 2
    assert wire["grant_id"] == "grant-018fbc96"
    assert decoded.signing_version == 2
    assert decoded.grant_id == "grant-018fbc96"
    assert json["signing_version"] == 2
    assert json["grant_id"] == "grant-018fbc96"
    assert Capability.identity_key(decoded) == Capability.identity_key(legacy)
  end

  test "missing protocol fields decode as legacy v1" do
    wire =
      legacy_capability()
      |> Capability.to_map()
      |> Map.drop(["signing_version", "grant_id"])

    decoded = Capability.from_map(wire)

    assert decoded.signing_version == 1
    assert decoded.grant_id == nil
  end

  defp legacy_capability do
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
