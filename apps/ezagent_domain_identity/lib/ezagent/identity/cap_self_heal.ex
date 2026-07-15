defmodule Ezagent.Identity.CapSelfHeal do
  @moduledoc """
  Durable enqueue seam for post-ready capability signing self-heal.

  Lifecycle activation calls only this non-waiting producer. Re-issuance and
  exact-artifact CAS execute later through the capability delivery outbox.
  """

  alias Ezagent.{Cmd, Router}
  alias Ezagent.Cap.HealRequest

  @doc false
  @spec enqueue_plan(URI.t(), Ezagent.Identity.CapReconciler.plan()) ::
          :ok | {:error, term()}
  def enqueue_plan(%URI{} = holder_uri, plan) when is_map(plan) do
    requests =
      Enum.map(Map.get(plan, :reissue, []), fn entry ->
        %HealRequest{expected: entry.cap, class: entry.class, action: entry.action}
      end) ++
        Enum.map(Map.get(plan, :quarantine, []), fn entry ->
          %HealRequest{
            expected: entry.cap,
            class: entry.class,
            action: {:quarantine, entry.reason}
          }
        end)

    result =
      Enum.reduce_while(requests, :ok, fn request, :ok ->
        case enqueue(holder_uri, request) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    if match?({:error, _reason}, result) do
      require Logger
      Logger.warning("cap self-heal enqueue failed holder=#{inspect(holder_uri)} result=#{inspect(result)}")
    end

    result
  end

  @doc false
  @spec enqueue(URI.t(), HealRequest.t()) :: :ok | {:error, term()}
  def enqueue(%URI{} = holder_uri, %HealRequest{} = request) do
    target = holder_uri |> Ezagent.URI.instance() |> Ezagent.URI.with_action(:identity, :heal_cap)

    %Cmd{
      target: target,
      action: :heal_cap,
      args: %{request: request},
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        mode: :cast,
        reply: :ignore,
        cap_delivery_producer: :identity_heal
      }
    }
    |> Router.dispatch()
    |> normalize_result()
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _result}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:unexpected_heal_enqueue_result, other}}
end
