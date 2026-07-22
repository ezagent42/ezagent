defmodule Ezagent.Socialware.TestCapHelper do
  @moduledoc false

  @downstream_actions [
    {:session, :send},
    {:surface, :put_version},
    {:surface, :approve},
    {:surface, :commit_settlement}
  ]

  def lifecycle_caps(%URI{} = session, %URI{} = caller, %URI{} = primary_target) do
    targets =
      [primary_target | Enum.map(@downstream_actions, &action_target(session, &1))]
      |> Enum.uniq_by(&URI.to_string/1)

    targets
    |> Enum.map(&Ezagent.Test.CapHelper.signed_action_cap!(&1, caller))
    |> MapSet.new()
  end

  @doc false
  def owner(workspace, label) when is_atom(workspace) and is_binary(label) do
    key = {__MODULE__, :owner, workspace, label}

    Process.get(key) ||
      tap(
        Ezagent.URI.entity(
          workspace,
          :user,
          "#{label}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
        ),
        &Process.put(key, &1)
      )
  end

  @doc false
  def spawn_session(args) when is_map(args) do
    case Ezagent.Kind.spawn(Ezagent.Entity.Session, args) do
      {:ok, _pid} = ok ->
        case Map.get(args, :owner_uri) do
          %URI{} = owner ->
            :ok = ensure_principal(owner)

            :ok =
              Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(
                Map.fetch!(args, :uri),
                owner
              )

          nil ->
            :ok
        end

        ok

      other ->
        other
    end
  end

  defp ensure_principal(owner) do
    case Ezagent.KindRegistry.lookup(owner) do
      {:ok, _pid} ->
        :ok

      :error ->
        {:ok, _row} =
          Ezagent.Users.create(
            owner,
            "socialware-fixture-#{System.unique_integer([:positive])}",
            []
          )

        case Ezagent.SpawnRegistry.spawn(owner) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "socialware test owner spawn failed: #{inspect(reason)}"
        end
    end
  end

  defp action_target(session, {behavior, action}) do
    Ezagent.URI.with_action(session, behavior, action)
  end
end
