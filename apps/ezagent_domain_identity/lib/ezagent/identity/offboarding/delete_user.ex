defmodule Ezagent.Identity.Offboarding.DeleteUser do
  @moduledoc false

  alias Ezagent.Cap.Authority
  alias Ezagent.Identity.Offboarding.{RevocationFence, StructuralTransfer}
  alias Ezagent.Provenance.DerivationEdges

  @spec invalidate(URI.t()) :: :ok | {:error, term()}
  def invalidate(%URI{} = user_uri) do
    descendants = DerivationEdges.descendants(user_uri)

    owned =
      user_uri
      |> DerivationEdges.ownership_descendants()
      |> MapSet.new(&Ezagent.URI.stable_key/1)

    principals = [user_uri | descendants] |> Enum.uniq_by(&Ezagent.URI.stable_key/1)

    with :ok <- RevocationFence.enroll(principals),
         :ok <- invalidate_one(user_uri, :user),
         :ok <- invalidate_descendants(descendants, user_uri, owned) do
      :ok
    end
  rescue
    error -> {:error, {:delete_user_invalidation_failed, error}}
  catch
    kind, reason -> {:error, {:delete_user_invalidation_failed, {kind, reason}}}
  end

  defp invalidate_descendants(descendants, deleted_user, owned) do
    Enum.reduce_while(descendants, :ok, fn uri, :ok ->
      case classify(uri, owned) do
        {:revoke, kind_type} -> continue(invalidate_one(uri, kind_type))
        :transfer -> continue(transfer_one(uri, deleted_user))
        :retain -> continue(RevocationFence.clear(uri))
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp invalidate_one(uri, kind_type) do
    with {:ok, _authority} <- Authority.regenesis(uri, kind_type),
         :ok <- Ezagent.EntityCaps.clear_self_license_persisted(uri),
         :ok <- RevocationFence.clear(uri) do
      :ok
    end
  end

  defp transfer_one(uri, deleted_user) do
    with :ok <- StructuralTransfer.transfer(uri, deleted_user),
         :ok <- RevocationFence.clear(uri) do
      :ok
    end
  end

  defp classify(%URI{scheme: "entity"} = uri, owned) do
    cond do
      Ezagent.URI.type?(uri, :agent) and MapSet.member?(owned, Ezagent.URI.stable_key(uri)) ->
        {:revoke, :agent}

      Ezagent.URI.type?(uri, :agent) ->
        :retain

      Ezagent.URI.type?(uri, :user) ->
        :retain

      true ->
        {:error, {:unsupported_entity_descendant, uri}}
    end
  end

  defp classify(%URI{scheme: scheme}, _owned)
       when scheme in ["session", "workspace", "template"],
       do: :transfer

  defp classify(%URI{scheme: "resource"}, _owned), do: :retain
  defp classify(uri, _owned), do: {:error, {:unsupported_derivation_descendant, uri}}

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}
end
