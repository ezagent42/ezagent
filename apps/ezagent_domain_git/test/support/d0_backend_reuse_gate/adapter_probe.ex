defmodule Ezagent.DomainGit.D0BackendReuseGate.AdapterProbe do
  @moduledoc false

  alias Ezagent.DomainGit.D0BackendReuseGate.{InProcessFake, SensitiveCredential}

  @spec request_with_lease(map(), map()) :: {:ok, map()} | {:error, atom()}
  def request_with_lease(lease, consume_request) do
    with :ok <- InProcessFake.prepare_lease(consume_request),
         {:ok, response} <- private_req(lease.sensitive),
         :ok <- InProcessFake.consume_lease(consume_request) do
      {:ok, response}
    end
  end

  defp private_req(%SensitiveCredential{value: value}) when is_binary(value) do
    :ok = InProcessFake.record_provider_effect()
    {:ok, %{status: 200, body: %{"login" => "alice-gh"}}}
  end
end
