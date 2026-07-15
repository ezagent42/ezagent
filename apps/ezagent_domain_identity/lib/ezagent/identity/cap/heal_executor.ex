defmodule Ezagent.Identity.Cap.HealExecutor do
  @moduledoc false

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Cap.HealRequest
  alias Ezagent.EntityCaps.SnapshotStore
  alias Ezagent.EntityCaps.UserStore
  alias Ezagent.Identity.{CapQuarantine, RecipeCapBinding}

  @doc false
  @spec execute(URI.t(), [Capability.t()], HealRequest.t()) ::
          {:ok, map(), list()} | {:error, term()}
  def execute(%URI{} = receiver, current_caps, %HealRequest{} = request)
      when is_list(current_caps) do
    user_caps = if Ezagent.URI.type?(receiver, :user), do: UserStore.load(receiver), else: []
    snapshot_caps = durable_snapshot_caps(receiver)

    current_exact_present? = exact_cap_present?(current_caps, request.expected)
    user_exact_present? = exact_cap_present?(user_caps, request.expected)
    snapshot_exact_present? = exact_cap_present?(snapshot_caps, request.expected)
    exact_present? = current_exact_present? or user_exact_present? or snapshot_exact_present?

    if exact_present? or match?({:refresh_binding, _ref}, request.action) do
      execute_present(
        receiver,
        current_caps,
        user_caps ++ snapshot_caps,
        request,
        exact_present?,
        user_exact_present? or snapshot_exact_present?
      )
    else
      :ok = CapQuarantine.close(receiver, request.expected)
      {:ok, %{status: :stale}, []}
    end
  end

  @doc false
  @spec quarantine(URI.t(), [Capability.t()], HealRequest.t(), term()) ::
          {:ok, map(), []} | {:error, term()}
  def quarantine(%URI{} = receiver, current_caps, %HealRequest{} = request, reason)
      when is_list(current_caps) do
    durable_caps =
      if(Ezagent.URI.type?(receiver, :user), do: UserStore.load(receiver), else: []) ++
        durable_snapshot_caps(receiver)

    caps = current_caps ++ durable_caps

    cond do
      signed_identity_replacement?(caps, request.expected, receiver) ->
        :ok = CapQuarantine.close_resolved(receiver, request.expected)
        {:ok, %{status: :stale}, []}

      not exact_cap_present?(caps, request.expected) ->
        :ok = CapQuarantine.close(receiver, request.expected)
        {:ok, %{status: :stale}, []}

      true ->
        with :ok <- CapQuarantine.record(receiver, request.expected, request.class, reason) do
          {:ok, %{status: :quarantined}, []}
        end
    end
  end

  defp execute_present(
         receiver,
         current_caps,
         user_caps,
         request,
         exact_present?,
         user_exact_present?
       ) do
    case resolve_replacement(receiver, current_caps ++ user_caps, request) do
      {:ok, %Capability{} = replacement} ->
        with :ok <- apply_exact_heal(receiver, request.expected, replacement) do
          :ok = CapQuarantine.close(receiver, request.expected)

          healed_caps =
            replace_or_materialize(
              current_caps,
              request.expected,
              replacement,
              user_exact_present?
            )

          effects =
            if healed_caps == current_caps do
              []
            else
              [
                {:set, :caps, MapSet.new(healed_caps)},
                {:emit, :cap_healed,
                 %{target_uri: receiver, cap: replacement, at: DateTime.utc_now()}}
              ]
            end

          {:ok, %{status: :healed}, effects}
        else
          {:error, reason} -> quarantine_failed_heal(receiver, request, reason)
        end

      {:ok, :no_match} when not exact_present? ->
        :ok = CapQuarantine.close(receiver, request.expected)
        {:ok, %{status: :stale}, []}

      {:ok, :no_match} ->
        quarantine_failed_heal(receiver, request, :binding_not_found)

      {:error, reason} ->
        quarantine_failed_heal(receiver, request, reason)
    end
  end

  defp resolve_replacement(receiver, current_caps, request) do
    existing =
      Enum.find(current_caps, fn
        %Capability{} = cap ->
          Capability.identity_key(cap) == Capability.identity_key(request.expected) and
            Cap.signed_and_valid?(cap, receiver)

        _other ->
          false
      end)

    if existing do
      {:ok, existing}
    else
      case request.action do
        {:reissue, authorization} -> Cap.issue(authorization, receiver, request.expected)
        {:refresh_binding, _ref} -> resolve_binding_replacement(receiver, request.expected)
      end
    end
  end

  defp resolve_binding_replacement(receiver, expected) do
    existing =
      case RecipeCapBinding.fetch(receiver) do
        {:ok, %{caps: caps}} ->
          Enum.find(caps, fn cap ->
            Capability.identity_key(cap) == Capability.identity_key(expected) and
              Cap.signed_and_valid?(cap, receiver)
          end)

        :not_found ->
          nil
      end

    if existing do
      {:ok, existing}
    else
      case RecipeCapBinding.refresh_exact(receiver, expected) do
        {:ok, %{replacement: replacement}} -> {:ok, replacement}
        {:ok, :no_match} -> {:ok, :no_match}
        {:error, reason} -> {:error, {:binding_refresh_failed, reason}}
      end
    end
  end

  defp apply_exact_heal(receiver, expected, replacement) do
    with true <- Cap.signed_and_valid?(replacement, receiver),
         :ok <- heal_user_home(receiver, expected, replacement),
         :ok <- heal_snapshot_home(receiver, expected, replacement) do
      :ok
    else
      false -> {:error, :invalid_cap_artifact}
      {:error, _reason} = error -> error
    end
  end

  defp heal_snapshot_home(receiver, expected, replacement) do
    case SnapshotStore.heal_exact(receiver, expected, replacement) do
      result when result in [:replaced, :no_match] -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp heal_user_home(receiver, expected, replacement) do
    if Ezagent.URI.type?(receiver, :user) do
      case UserStore.heal_exact(receiver, expected, replacement) do
        result when result in [:replaced, :no_match] -> :ok
        {:error, :not_found} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp quarantine_failed_heal(receiver, request, reason) do
    with :ok <-
           CapQuarantine.record(
             receiver,
             request.expected,
             request.class,
             {:heal_failed, reason}
           ) do
      {:ok, %{status: :quarantined}, []}
    end
  end

  defp exact_cap_present?(caps, expected), do: Enum.any?(caps, &(&1 === expected))

  defp signed_identity_replacement?(caps, expected, receiver) do
    expected_key = Capability.identity_key(expected)

    Enum.any?(caps, fn
      %Capability{} = cap ->
        Capability.identity_key(cap) == expected_key and
          Cap.signed_and_valid?(cap, receiver)

      _other ->
        false
    end)
  end

  defp durable_snapshot_caps(receiver) do
    case SnapshotStore.load(receiver) do
      {:ok, caps} -> caps
      _ -> []
    end
  end

  defp replace_or_materialize(caps, expected, replacement, user_exact_present?) do
    cond do
      exact_cap_present?(caps, expected) ->
        Enum.map(caps, fn cap -> if cap === expected, do: replacement, else: cap end)

      user_exact_present? and not same_identity_present?(caps, expected) ->
        [replacement | caps]

      true ->
        caps
    end
  end

  defp same_identity_present?(caps, expected) do
    expected_key = Capability.identity_key(expected)

    Enum.any?(caps, fn
      %Capability{} = cap -> Capability.identity_key(cap) == expected_key
      _other -> false
    end)
  end
end
