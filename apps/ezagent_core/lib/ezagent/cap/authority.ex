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
  alias Ezagent.Ecto.KindCapAuthority
  alias EzagentCore.Repo

  @derive {Inspect, except: [:private_key]}
  @enforce_keys [:uri, :kind_type, :generation, :key_id, :public_key, :private_key]
  defstruct [:uri, :kind_type, :generation, :key_id, :public_key, :private_key]

  @opaque t :: %__MODULE__{
            uri: URI.t(),
            kind_type: atom(),
            generation: pos_integer(),
            key_id: String.t(),
            public_key: binary(),
            private_key: binary()
          }

  @doc false
  @spec open(URI.t(), atom()) :: {:ok, t()} | {:error, term()}
  def open(%URI{} = uri, kind_type) when is_atom(kind_type) do
    uri_string = Ezagent.URI.stable_key(uri)

    case KindCapAuthority.active(uri_string) do
      %KindCapAuthority{} = row -> {:ok, from_row(row)}
      nil -> genesis(uri, kind_type)
    end
  end

  @doc false
  @spec anchor(URI.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def anchor(%URI{} = uri) do
    case KindCapAuthority.active(Ezagent.URI.stable_key(uri)) do
      %KindCapAuthority{anchor: anchor} -> {:ok, :erlang.binary_to_term(anchor, [:safe])}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  @spec retire(URI.t()) :: :ok
  def retire(%URI{} = uri), do: KindCapAuthority.retire_active(Ezagent.URI.stable_key(uri))

  @doc false
  @spec regenesis(URI.t(), atom(), URI.t()) :: {:ok, t()} | {:error, term()}
  def regenesis(%URI{} = uri, kind_type, %URI{} = presenter) when is_atom(kind_type) do
    if same_uri?(presenter, admin_uri()) do
      uri_string = Ezagent.URI.stable_key(uri)

      Repo.transaction(fn ->
        :ok = KindCapAuthority.retire_active(uri_string)
        next_generation = next_generation(uri_string)

        case insert_generation(uri, kind_type, next_generation) do
          {:ok, authority} -> authority
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, authority} -> {:ok, authority}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :admin_required}
    end
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
      verify_signature(authority.public_key, cap, presenter)
  end

  def verify(%__MODULE__{}, %Capability{}, %URI{}), do: false

  @doc false
  @spec verify_durable_current(URI.t(), Capability.t(), URI.t()) :: boolean()
  def verify_durable_current(
        %URI{} = target,
        %Capability{grantee_uri: %URI{} = grantee} = cap,
        %URI{} = receiver
      ) do
    with {:ok, artifact_target} <- target_uri(cap),
         true <- same_uri?(artifact_target, target),
         true <- same_uri?(grantee, receiver),
         %{generation: generation, public_key: public_key} <-
           KindCapAuthority.active_public(Ezagent.URI.stable_key(target)),
         expected_key_id <- key_id(public_key, generation),
         true <- cap.key_id == expected_key_id do
      verify_signature(public_key, cap, receiver)
    else
      _reason -> false
    end
  end

  def verify_durable_current(%URI{}, %Capability{}, %URI{}), do: false

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
  @spec verify_current(Capability.t(), URI.t()) :: boolean()
  def verify_current(%Capability{} = cap, %URI{} = presenter) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{} = authority -> verify(authority, cap, presenter)
      nil -> false
    end
  end

  @doc """
  Verify a cap against the TARGET's CURRENT active authority row, read fresh
  from the DB on every call (unified-revocation Phase F-1, DECISION #2 / MF4).

  This is the revocation-correct verify: `regenesis/3` flips the DB active
  row atomically, so a gen-bumped target's old-gen caps fail immediately —
  independent of whether the target's process is alive or busy. The current
  `key_id` comes from the committed active row (never the process-dict
  `verify_current/2` authority, which a live process caches stale-on-bump);
  the public key for that immutable `key_id` is memoized in
  `Ezagent.Cap.AuthorityCache` (read-through to the durable row on a miss).

  Fail-closed: a target with no active row, an unreadable store, a `key_id`
  mismatch, a presenter other than the grantee, or a bad signature all
  return `false`.
  """
  @spec verify_against_current(Capability.t(), URI.t(), URI.t()) :: boolean()
  def verify_against_current(
        %Capability{signature: signature, grantee_uri: presenter} = cap,
        %URI{} = presenter,
        %URI{} = target
      )
      when is_binary(signature) do
    with {:ok, current_key_id} <- current_key_id(target),
         true <- cap.key_id == current_key_id,
         {:ok, public_key} <- Ezagent.Cap.AuthorityCache.public_key(current_key_id) do
      :crypto.verify(
        :eddsa,
        :none,
        Signing.signing_payload(cap),
        signature,
        [public_key, :ed25519]
      )
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def verify_against_current(%Capability{}, %URI{}, %URI{}), do: false

  defp current_key_id(%URI{} = target) do
    target_string = target |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()

    case KindCapAuthority.active(target_string) do
      %KindCapAuthority{key_id: key_id} -> {:ok, key_id}
      nil -> :error
    end
  end

  @doc false
  @spec current_target?(URI.t()) :: boolean()
  def current_target?(%URI{} = target) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{uri: uri} -> same_uri?(uri, Ezagent.URI.instance(target))
      nil -> false
    end
  end

  @doc false
  @spec current_kind_type() :: {:ok, atom()} | {:error, :authority_unavailable}
  def current_kind_type do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{kind_type: kind_type} -> {:ok, kind_type}
      nil -> {:error, :authority_unavailable}
    end
  end

  @doc false
  @spec issue_current(Ezagent.Cap.Grant.intent()) :: {:ok, Capability.t()} | {:error, term()}
  def issue_current(%Ezagent.Cap.Grant{} = intent) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{} = authority -> {:ok, Ezagent.Cap.Grant.issue(authority, intent)}
      nil -> {:error, :authority_unavailable}
    end
  end

  @doc false
  @spec target_uri(Capability.t()) :: {:ok, URI.t()} | {:error, :concrete_target_required}
  def target_uri(%Capability{instance: %URI{} = instance}),
    do: {:ok, Ezagent.URI.instance(instance)}

  def target_uri(%Capability{}), do: {:error, :concrete_target_required}

  defp key_id(public_key, generation) do
    fingerprint = :crypto.hash(:sha256, public_key) |> Base.url_encode64(padding: false)
    "kind-g#{generation}:#{fingerprint}"
  end

  defp verify_signature(public_key, %Capability{signature: signature} = cap, %URI{})
       when is_binary(public_key) and is_binary(signature) do
    :crypto.verify(
      :eddsa,
      :none,
      Signing.signing_payload(cap),
      signature,
      [public_key, :ed25519]
    )
  end

  defp verify_signature(_public_key, %Capability{}, %URI{}), do: false

  defp genesis(uri, kind_type) do
    uri_string = Ezagent.URI.stable_key(uri)

    Repo.transaction(fn ->
      case KindCapAuthority.list(uri_string) do
        [] ->
          unless same_uri?(uri, admin_uri()) do
            case KindCapAuthority.active(Ezagent.URI.stable_key(admin_uri())) do
              nil ->
                case insert_generation(admin_uri(), :user, 1) do
                  {:ok, _admin_authority} -> :ok
                  {:error, reason} -> Repo.rollback(reason)
                end

              _row ->
                :ok
            end
          end

          case insert_generation(uri, kind_type, 1) do
            {:ok, authority} -> authority
            {:error, reason} -> Repo.rollback(reason)
          end

        _historical ->
          Repo.rollback(:regenesis_required)
      end
    end)
    |> case do
      {:ok, authority} -> {:ok, authority}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_generation(uri, kind_type, generation) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    authority = %__MODULE__{
      uri: uri,
      kind_type: kind_type,
      generation: generation,
      key_id: key_id(public_key, generation),
      public_key: public_key,
      private_key: private_key
    }

    anchor =
      %Capability{
        kind: kind_type,
        behavior: :any,
        action: :grant,
        instance: uri,
        workspace_uri: Ezagent.Capability.workspace_of(uri),
        granted_by: admin_uri(),
        granted_at: DateTime.utc_now(),
        grantee_uri: admin_uri()
      }
      |> then(&sign(authority, &1))

    attrs = %{
      uri: Ezagent.URI.stable_key(uri),
      generation: generation,
      kind_type: Atom.to_string(kind_type),
      key_id: authority.key_id,
      public_key: public_key,
      private_key: private_key,
      anchor: :erlang.term_to_binary(anchor, [:deterministic]),
      sealed: true,
      active: true,
      inserted_at: DateTime.utc_now()
    }

    case KindCapAuthority.insert(attrs) do
      {:ok, _row} -> {:ok, authority}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp from_row(%KindCapAuthority{} = row) do
    %__MODULE__{
      uri: Ezagent.URI.new!(row.uri),
      kind_type: String.to_existing_atom(row.kind_type),
      generation: row.generation,
      key_id: row.key_id,
      public_key: row.public_key,
      private_key: row.private_key
    }
  end

  defp next_generation(uri_string) do
    uri_string
    |> KindCapAuthority.list()
    |> Enum.map(& &1.generation)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp admin_uri, do: Ezagent.URI.user(:system, :admin)
  defp same_uri?(left, right), do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
