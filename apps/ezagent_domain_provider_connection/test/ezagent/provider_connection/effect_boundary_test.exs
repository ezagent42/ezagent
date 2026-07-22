defmodule Ezagent.ProviderConnection.EffectBoundaryTest do
  use ExUnit.Case, async: true

  alias Ezagent.ProviderConnection.EffectBoundary

  test "returns the effect result unchanged for ok and error tuples" do
    assert {:ok, %{credential_ref: "ref"}} =
             EffectBoundary.invoke(
               fn -> {:ok, %{credential_ref: "ref"}} end,
               :backend_unavailable
             )

    assert {:error, :correlation_conflict} =
             EffectBoundary.invoke(
               fn -> {:error, :correlation_conflict} end,
               :backend_unavailable
             )

    assert :ok = EffectBoundary.invoke(fn -> :ok end, :backend_unavailable)
  end

  test "a raised exception is normalized to the closed error without its payload" do
    payload =
      "HTTP 401 body: Authorization: Bearer SECRET-TOKEN-#{System.unique_integer([:positive])}"

    result =
      EffectBoundary.invoke(fn -> raise payload end, :provider_protocol_failed)

    assert {:error, :provider_protocol_failed} = result
    refute inspect(result) =~ "SECRET-TOKEN"
  end

  test "a thrown value is normalized to the closed error without its payload" do
    assert {:error, :backend_unavailable} =
             EffectBoundary.invoke(
               fn -> throw({:provider_body, "SECRET-TOKEN"}) end,
               :backend_unavailable
             )
  end

  test "an exit is normalized to the closed error without its payload" do
    assert {:error, :backend_unavailable} =
             EffectBoundary.invoke(
               fn -> exit({:provider_timeout, "SECRET-TOKEN"}) end,
               :backend_unavailable
             )
  end

  test "an Erlang error is normalized to the closed error" do
    assert {:error, :provider_protocol_failed} =
             EffectBoundary.invoke(
               fn -> :erlang.error({:finch_error, "SECRET-TOKEN"}) end,
               :provider_protocol_failed
             )
  end
end
