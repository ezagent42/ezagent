defmodule Ezagent.DomainGit.D0BackendReuseGate.RemoteShapedFake do
  @moduledoc false

  @behaviour Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  @behaviour Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend

  alias Ezagent.DomainGit.D0BackendReuseGate.{
    InProcessFake,
    RemoteSeal,
    RemoteTransport,
    SensitiveCredential
  }

  @tamper_key {__MODULE__, :tamper_next_sealed_response}

  def reset, do: call(:reset, %{})
  def advance_time(seconds), do: call(:advance_time, %{seconds: seconds})
  def authorization_count, do: call(:authorization_count, %{})
  def credential_store_count, do: call(:credential_store_count, %{})
  def provider_effect_count, do: call(:provider_effect_count, %{})
  def command_effect_count, do: call(:command_effect_count, %{})
  def prepare_lease(request), do: call(:prepare_lease, request)
  def record_provider_effect, do: call(:record_provider_effect, %{})

  def tamper_next_sealed_response do
    Process.put(@tamper_key, true)
    :ok
  end

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def begin_authorization(request), do: call(:begin_authorization, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def consume_callback(request), do: call(:consume_callback, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def reauthenticate(request), do: call(:reauthenticate, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.ProviderAuthorizationBackend
  def cancel_authorization(request), do: call(:cancel_authorization, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def store(request), do: call(:store, seal_material(request))

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def replace(request), do: call(:replace, seal_material(request))

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def status(request), do: call(:status, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def lease_for_operation(request) do
    case call(:lease_for_operation, request) do
      {:ok, %{sealed_credential: sealed} = lease} ->
        sealed = maybe_tamper(sealed)

        case RemoteSeal.unseal(sealed) do
          {:ok, value} ->
            sensitive = %SensitiveCredential{value: value}
            {:ok, lease |> Map.delete(:sealed_credential) |> Map.put(:sensitive, sensitive)}

          {:error, :provider_response_invalid} = error ->
            error
        end

      other ->
        other
    end
  end

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def consume_lease(request), do: call(:consume_lease, request)

  @impl Ezagent.DomainGit.D0BackendReuseGate.CredentialBackend
  def revoke(request), do: call(:revoke, request)

  defp call(operation, request) do
    case RemoteTransport.round_trip(operation, request, &dispatch/2) do
      {:transport_error, _reason} -> {:error, unavailable_error(operation)}
      result -> result
    end
  end

  defp unavailable_error(operation)
       when operation in [
              :begin_authorization,
              :consume_callback,
              :reauthenticate,
              :cancel_authorization
            ],
       do: :authorization_backend_unavailable

  defp unavailable_error(_operation), do: :credential_backend_unavailable

  defp dispatch(:reset, _request), do: InProcessFake.reset(InProcessFake)

  defp dispatch(:advance_time, request),
    do: InProcessFake.advance_time(InProcessFake, request.seconds)

  defp dispatch(:authorization_count, _request),
    do: InProcessFake.authorization_count(InProcessFake)

  defp dispatch(:credential_store_count, _request),
    do: InProcessFake.credential_store_count(InProcessFake)

  defp dispatch(:provider_effect_count, _request),
    do: InProcessFake.provider_effect_count(InProcessFake)

  defp dispatch(:command_effect_count, _request),
    do: InProcessFake.command_effect_count(InProcessFake)

  defp dispatch(:record_provider_effect, _request), do: InProcessFake.record_provider_effect()
  defp dispatch(:prepare_lease, request), do: InProcessFake.prepare_lease(request)
  defp dispatch(:begin_authorization, request), do: InProcessFake.begin_authorization(request)
  defp dispatch(:consume_callback, request), do: InProcessFake.consume_callback(request)
  defp dispatch(:reauthenticate, request), do: InProcessFake.reauthenticate(request)
  defp dispatch(:cancel_authorization, request), do: InProcessFake.cancel_authorization(request)
  defp dispatch(:store, request), do: request |> unseal_material() |> InProcessFake.store()
  defp dispatch(:replace, request), do: request |> unseal_material() |> InProcessFake.replace()
  defp dispatch(:status, request), do: InProcessFake.status(request)

  defp dispatch(:lease_for_operation, request) do
    InProcessFake.lease_for_operation_sealed(request)
  end

  defp dispatch(:consume_lease, request), do: InProcessFake.consume_lease(request)
  defp dispatch(:revoke, request), do: InProcessFake.revoke(request)

  defp seal_material(%{credential_material: material} = request) do
    request
    |> Map.delete(:credential_material)
    |> Map.put(:sealed_credential, RemoteSeal.seal(material))
  end

  defp unseal_material(%{sealed_credential: sealed} = request) do
    {:ok, value} = RemoteSeal.unseal(sealed)
    request |> Map.delete(:sealed_credential) |> Map.put(:credential_material, value)
  end

  defp maybe_tamper(sealed) do
    if Process.delete(@tamper_key) do
      raw = Base.url_decode64!(sealed, padding: false)
      size = byte_size(raw)
      <<prefix::binary-size(size - 1), last>> = raw
      Base.url_encode64(prefix <> <<:erlang.bxor(last, 1)>>, padding: false)
    else
      sealed
    end
  end
end
