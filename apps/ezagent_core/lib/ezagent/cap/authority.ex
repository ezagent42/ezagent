defmodule Ezagent.Cap.Authority do
  @moduledoc """
  Framework-owned per-Kind capability authority compartment.

  The authority is private top-level `Ezagent.Kind.Server` state. It is never
  merged into a Behavior slice, handler context, snapshot, event, log, or
  generic admin listing. Callers outside the framework receive capability
  artifacts, never key material.

  This boundary is defined for the reviewed-code (Path A) threat model. Code
  already executing maliciously inside the BEAM is explicitly out of scope.
  """

  alias Ezagent.Cap.Signing
  alias Ezagent.Capability

  @derive {Inspect, except: [:private_key]}
  @enforce_keys [:uri, :generation, :key_id, :public_key, :private_key]
  defstruct [:uri, :generation, :key_id, :public_key, :private_key]

  @opaque t :: %__MODULE__{
            uri: URI.t(),
            generation: pos_integer(),
            key_id: String.t(),
            public_key: binary(),
            private_key: binary()
          }

  @doc false
  @spec open(URI.t()) :: t()
  def open(%URI{} = uri) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %__MODULE__{
      uri: uri,
      generation: 1,
      key_id: key_id(public_key, 1),
      public_key: public_key,
      private_key: private_key
    }
  end

  @doc false
  @spec sign(t(), Capability.t()) :: Capability.t()
  def sign(%__MODULE__{} = authority, %Capability{} = cap) do
    cap = %{cap | key_id: authority.key_id}

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        Signing.signing_payload(cap),
        [authority.private_key, :ed25519]
      )

    %{cap | signature: signature}
  end

  @doc false
  @spec verify(t(), Capability.t(), URI.t()) :: boolean()
  def verify(
        %__MODULE__{} = authority,
        %Capability{signature: signature, grantee_uri: presenter} = cap,
        %URI{} = presenter
      )
      when is_binary(signature) do
    cap.key_id == authority.key_id and
      :crypto.verify(
        :eddsa,
        :none,
        Signing.signing_payload(cap),
        signature,
        [authority.public_key, :ed25519]
      )
  end

  def verify(%__MODULE__{}, %Capability{}, %URI{}), do: false

  @doc false
  @spec sign_for_target(Capability.t()) :: {:ok, Capability.t()} | {:error, term()}
  def sign_for_target(%Capability{} = cap) do
    with {:ok, target} <- authority_target(cap),
         {:ok, pid} <- Ezagent.KindRegistry.lookup(target) do
      if pid == self() do
        case Process.get({__MODULE__, :current}) do
          %__MODULE__{} = authority -> {:ok, sign(authority, cap)}
          nil -> {:error, :authority_unavailable}
        end
      else
        GenServer.call(pid, {:ezagent_cap_sign, cap})
      end
    end
  end

  @doc false
  @spec with_current(t(), (-> result)) :: result when result: term()
  def with_current(%__MODULE__{} = authority, fun) when is_function(fun, 0) do
    key = {__MODULE__, :current}
    previous = Process.put(key, authority)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  @doc false
  @spec verify_for_target(Capability.t(), URI.t()) :: boolean()
  def verify_for_target(%Capability{} = cap, %URI{} = presenter) do
    with {:ok, target} <- authority_target(cap),
         {:ok, pid} <- Ezagent.KindRegistry.lookup(target) do
      if pid == self() do
        case Process.get({__MODULE__, :current}) do
          %__MODULE__{} = authority -> verify(authority, cap, presenter)
          nil -> false
        end
      else
        GenServer.call(pid, {:ezagent_cap_verify, cap, presenter})
      end
    else
      _ -> false
    end
  end

  defp key_id(public_key, generation) do
    fingerprint = :crypto.hash(:sha256, public_key) |> Base.url_encode64(padding: false)
    "kind-g#{generation}:#{fingerprint}"
  end

  defp authority_target(%Capability{instance: %URI{} = instance}),
    do: {:ok, Ezagent.URI.instance(instance)}

  defp authority_target(%Capability{instance: {_scope, %URI{} = instance}}),
    do: {:ok, Ezagent.URI.instance(instance)}

  defp authority_target(%Capability{instance: :any, granted_by: %URI{} = granted_by}),
    do: {:ok, Ezagent.URI.instance(granted_by)}

  defp authority_target(%Capability{}), do: {:error, :missing_target_authority}
end
