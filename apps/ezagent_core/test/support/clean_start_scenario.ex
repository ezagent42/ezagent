defmodule Ezagent.Test.CleanStartScenario do
  @moduledoc false

  alias Ezagent.Cap.{Authority, Grant, GrantArtifact, RevocationLedger}
  alias Ezagent.Capability
  alias EzagentCore.Repo

  @doc false
  def run_first_boot! do
    holder = proof_holder()
    self_license = issue_self_license!(holder)
    first = issue_proof_artifact!()

    expect!(:ok, identity_store_call(:initialize, [holder, [self_license]]))
    expect!(:ok, identity_store_call(:persist, [holder, [self_license, first]]))
    assert_authorized!(holder, first)

    case identity_store_call(:revoke_cap, [holder, first]) do
      {:ok, %Capability{grant_id: grant_id}} when grant_id == first.grant_id -> :ok
      other -> Mix.raise("clean-start exact revoke failed: #{inspect(other)}")
    end

    assert_denied!(holder, first)

    second = issue_proof_artifact!()

    if second.grant_id == first.grant_id do
      Mix.raise("clean-start re-grant reused grant_id #{first.grant_id}")
    end

    expect!(:ok, identity_store_call(:persist, [holder, [self_license, second]]))
    assert_authorized!(holder, second)
    Mix.shell().info("clean-start first boot grant/revoke/re-grant scenario passed")
  end

  @doc false
  def run_cold_boot! do
    holder = proof_holder()

    caps =
      case identity_store_call(:fetch_durable_caps, [holder]) do
        {:ok, artifacts} -> artifacts
        other -> Mix.raise("clean-start cold boot Store read failed: #{inspect(other)}")
      end

    current =
      Enum.find(caps, fn cap ->
        cap.action == :send and same_instance?(cap.instance, proof_target())
      end) || Mix.raise("clean-start cold boot lost the re-granted artifact")

    old_grant_id = revoked_proof_grant_id!()

    if old_grant_id == current.grant_id do
      Mix.raise("clean-start cold boot found the current grant in the revocation ledger")
    end

    old = issue_proof_artifact!(old_grant_id)
    assert_denied!(holder, old)
    assert_authorized!(holder, current)

    expect!(
      {:error, {:revoked_capability_grants, [old_grant_id]}},
      RevocationLedger.ensure_unrevoked(proof_workspace(), [old])
    )

    expect!(:ok, RevocationLedger.ensure_unrevoked(proof_workspace(), [current]))
    Mix.shell().info("clean-start cold boot revocation persistence scenario passed")
  end

  @doc false
  def validate_anchor!(uri, encoded) when is_binary(uri) and is_binary(encoded) do
    artifact = decode_anchor!(uri, encoded)
    target = Ezagent.URI.new!(uri)
    presenter = artifact.grantee_uri

    unless match?(%URI{}, presenter) and
             Authority.verify_against_current(artifact, presenter, target) do
      Mix.raise("clean seed produced a stale or invalid authority anchor for #{uri}")
    end
  end

  defp decode_anchor!(uri, encoded) do
    with %Capability{} = artifact <- :erlang.binary_to_term(encoded, [:safe]),
         {:ok, %Capability{} = validated} <- GrantArtifact.validate(artifact) do
      validated
    else
      _ -> Mix.raise("clean seed produced a malformed authority anchor for #{uri}")
    end
  rescue
    _ -> Mix.raise("clean seed produced an unsafe authority anchor for #{uri}")
  end

  defp issue_self_license!(holder) do
    {:ok, authority} = Authority.open(holder, :agent, :created)

    request =
      Capability.cap(:agent, identity_action_set(), :self_license, holder, proof_workspace())

    intent = Grant.freeze(holder, holder, holder, request)

    case Grant.issue_self_license(authority, intent) do
      {:ok, %Capability{} = artifact} -> artifact
      other -> Mix.raise("clean-start self-license issuance failed: #{inspect(other)}")
    end
  end

  defp issue_proof_artifact!(grant_id \\ nil) do
    holder = proof_holder()
    target = proof_target()
    {:ok, authority} = Authority.open(target, :session, :created)

    request =
      Capability.cap(:session, session_action_set(), :send, target, proof_workspace())

    artifact = Grant.issue(authority, Grant.freeze(target, holder, holder, request))

    case {artifact, grant_id} do
      {%Capability{} = issued, nil} ->
        issued

      {%Capability{} = issued, id} when is_binary(id) ->
        Authority.sign(authority, %{issued | grant_id: id})

      {other, _grant_id} ->
        Mix.raise("clean-start proof grant issuance failed: #{inspect(other)}")
    end
  end

  defp assert_authorized!(holder, artifact) do
    case Ezagent.Cap.authorize(holder, [artifact], proof_needed()) do
      {:ok, %Capability{grant_id: grant_id}} when grant_id == artifact.grant_id -> :ok
      other -> Mix.raise("clean-start authorization failed: #{inspect(other)}")
    end
  end

  defp assert_denied!(holder, artifact) do
    case Ezagent.Cap.authorize(holder, [artifact], proof_needed()) do
      {:error, :no_matching_cap} -> :ok
      other -> Mix.raise("clean-start revoked artifact was not denied: #{inspect(other)}")
    end
  end

  defp revoked_proof_grant_id! do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT grant_id::text FROM cap_revocations " <>
          "WHERE holder_uri = $1 AND target_uri = $2 ORDER BY revoked_at",
        [Ezagent.URI.stable_key(proof_holder()), Ezagent.URI.stable_key(proof_target())]
      )

    case result.rows do
      [[grant_id]] -> grant_id
      rows -> Mix.raise("clean-start expected one revoked proof grant, got #{inspect(rows)}")
    end
  end

  defp proof_needed do
    %{
      kind: :session,
      behavior: session_action_set(),
      action: :send,
      instance: proof_target(),
      workspace_uri: proof_workspace()
    }
  end

  defp proof_holder, do: Ezagent.URI.agent("clean-start", "revocation-proof")
  defp proof_target, do: Ezagent.URI.session("clean-start", "default", "revocation-proof")
  defp proof_workspace, do: Ezagent.URI.workspace("clean-start")
  defp identity_action_set, do: Module.concat([Ezagent, ActionSet, Identity])
  defp session_action_set, do: Module.concat([Ezagent, ActionSet, Session])
  defp identity_store_call(function, args), do: apply(identity_store(), function, args)
  defp identity_store, do: Module.concat([Ezagent, IdentityCaps, Store])

  defp same_instance?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(Ezagent.URI.instance(left)) == Ezagent.URI.stable_key(right)

  defp same_instance?(_left, _right), do: false

  defp expect!(expected, expected), do: :ok

  defp expect!(expected, actual) do
    Mix.raise("clean-start expected #{inspect(expected)}, got #{inspect(actual)}")
  end
end
