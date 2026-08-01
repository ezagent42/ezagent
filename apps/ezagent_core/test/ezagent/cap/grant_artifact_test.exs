defmodule Ezagent.Cap.GrantArtifactTest do
  use ExUnit.Case, async: true

  alias Ezagent.Cap.GrantArtifact
  alias Ezagent.Capability

  describe "validate/1" do
    test "accepts a complete issued artifact and returns it" do
      artifact = artifact()

      assert {:ok, ^artifact} = GrantArtifact.validate(artifact)
      assert GrantArtifact.valid_grant_id?(artifact.grant_id)
    end

    test "requires the canonical lowercase hyphenated UUID representation" do
      canonical = Ecto.UUID.generate()
      uppercase = String.upcase(canonical)
      compact = String.replace(canonical, "-", "")

      assert GrantArtifact.valid_grant_id?(canonical)
      refute GrantArtifact.valid_grant_id?(uppercase)
      refute GrantArtifact.valid_grant_id?(compact)
      refute GrantArtifact.valid_grant_id?(nil)

      assert {:error, :missing_grant_id} =
               GrantArtifact.validate(%{artifact() | grant_id: nil})

      assert {:error, :missing_grant_id} =
               GrantArtifact.validate(%{artifact() | grant_id: ""})

      assert {:error, :invalid_grant_id} =
               GrantArtifact.validate(%{artifact() | grant_id: uppercase})

      assert {:error, :invalid_grant_id} =
               GrantArtifact.validate(%{artifact() | grant_id: compact})
    end

    test "treats empty signed-artifact metadata as missing" do
      assert {:error, :missing_signature} =
               GrantArtifact.validate(%{artifact() | signature: nil})

      assert {:error, :missing_signature} =
               GrantArtifact.validate(%{artifact() | signature: ""})

      assert {:error, :missing_key_id} =
               GrantArtifact.validate(%{artifact() | key_id: nil})

      assert {:error, :missing_key_id} =
               GrantArtifact.validate(%{artifact() | key_id: ""})

      assert {:error, :missing_grantee_uri} =
               GrantArtifact.validate(%{artifact() | grantee_uri: nil})
    end

    test "distinguishes wrong field types from malformed URI values" do
      assert {:error, {:invalid_field, :kind}} =
               GrantArtifact.validate(%{artifact() | kind: "session"})

      assert {:error, {:invalid_field, :granted_at}} =
               GrantArtifact.validate(%{artifact() | granted_at: "now"})

      assert {:error, {:invalid_field, :grantee_uri}} =
               GrantArtifact.validate(%{artifact() | grantee_uri: "entity://team/user/alice"})

      assert {:error, {:invalid_uri, :grantee_uri}} =
               GrantArtifact.validate(%{artifact() | grantee_uri: %URI{path: "alice"}})

      assert {:error, {:invalid_uri, :workspace_uri}} =
               GrantArtifact.validate(%{artifact() | workspace_uri: %URI{path: "team"}})
    end

    test "rejects values that are not capabilities" do
      assert {:error, :not_capability} = GrantArtifact.validate(%{})
      assert {:error, :not_capability} = GrantArtifact.validate(:not_a_capability)
    end
  end

  describe "from_map/1 and from_term/1" do
    test "decode and validate the same issued artifact contract" do
      artifact = artifact()

      assert {:ok, decoded_map} = artifact |> Capability.to_map() |> GrantArtifact.from_map()
      assert decoded_map == artifact

      binary = :erlang.term_to_binary(artifact, [:deterministic])
      assert {:ok, ^artifact} = GrantArtifact.from_term(binary)
    end

    test "return tagged errors instead of raising for malformed input" do
      assert {:error, :not_capability} = GrantArtifact.from_map(%{"kind" => "session"})
      assert {:error, :invalid_term} = GrantArtifact.from_term(<<0, 1, 2>>)
      assert {:error, :invalid_term} = GrantArtifact.from_term(:not_binary)

      not_a_capability = :erlang.term_to_binary(%{kind: :session})
      assert {:error, :invalid_term} = GrantArtifact.from_term(not_a_capability)

      unsafe = :erlang.term_to_binary(fn -> :ok end)
      assert {:error, :invalid_term} = GrantArtifact.from_term(unsafe)
    end
  end

  describe "validate_set/2" do
    test "returns a MapSet only when every artifact is valid" do
      first = artifact()
      second = %{artifact() | grant_id: Ecto.UUID.generate()}

      assert {:ok, caps} = GrantArtifact.validate_set([first, second], :store)
      assert caps == MapSet.new([first, second])
    end

    test "rejects the entire carrier with its member index and reason" do
      first = artifact()
      invalid = %{artifact() | signature: nil}
      third = %{artifact() | grant_id: Ecto.UUID.generate()}

      assert {:error, {:invalid_grant_artifact, :snapshot, 1, :missing_signature}} =
               GrantArtifact.validate_set([first, invalid, third], :snapshot)
    end

    test "rejects a non-enumerable carrier without raising" do
      assert {:error, {:invalid_grant_artifact, :store, 0, :not_capability}} =
               GrantArtifact.validate_set(:not_a_set, :store)
    end
  end

  defp artifact do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.new!("session://team-alpha/default/chat"),
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: Ezagent.URI.new!("entity://team-alpha/user/issuer"),
      granted_at: ~U[2026-08-01 00:00:00Z],
      signature: <<1, 2, 3>>,
      key_id: "kind-g1:test-key",
      grantee_uri: Ezagent.URI.new!("entity://team-alpha/user/alice"),
      grant_id: Ecto.UUID.generate()
    }
  end
end
