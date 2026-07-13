defmodule Ezagent.Session.OrchestratorBinding do
  @moduledoc """
  Durable session-to-orchestrator binding with materialization validity.

  The value is stored under the Session working-copy key `:orchestrator_uri`.
  Its URI is the exact random agent URI exposed to the bridge. The adjacent
  `:orchestrator_materialization_epoch` is the session's current generation;
  a binding is serviceable only when both epochs match and its status is active.
  Tombstones retain the URI so cold lookup can locate the session and fail loud.
  """

  @enforce_keys [:uri, :epoch, :status]
  defstruct [:uri, :epoch, :status, :reason]

  @type status :: :active | :tombstone
  @type t :: %__MODULE__{
          uri: URI.t(),
          epoch: String.t() | nil,
          status: status(),
          reason: term() | nil
        }

  @spec new_epoch() :: String.t()
  def new_epoch, do: Ecto.UUID.generate()

  @spec active(URI.t(), String.t()) :: t()
  def active(%URI{} = uri, epoch) when is_binary(epoch) and epoch != "" do
    %__MODULE__{uri: uri, epoch: epoch, status: :active, reason: nil}
  end

  @spec tombstone(URI.t(), String.t(), term()) :: t()
  def tombstone(%URI{} = uri, epoch, reason) when is_binary(epoch) and epoch != "" do
    %__MODULE__{uri: uri, epoch: epoch, status: :tombstone, reason: reason}
  end

  @doc "Decode a persisted binding without deciding whether it is serviceable."
  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(%__MODULE__{} = binding), do: validate(binding)

  def decode(%{} = value) do
    uri = Map.get(value, :uri) || Map.get(value, "uri")
    epoch = Map.get(value, :epoch) || Map.get(value, "epoch")
    status = normalize_status(Map.get(value, :status) || Map.get(value, "status"))
    reason = Map.get(value, :reason) || Map.get(value, "reason")

    validate(%__MODULE__{uri: uri, epoch: epoch, status: status, reason: reason})
  end

  # A pre-P1 bare URI is discoverable but never serviceable. Giving it a nil
  # epoch lets the reader locate the session and take the epoch-mismatch repair
  # path instead of silently serving an unproved binding.
  def decode(%URI{} = uri) do
    {:ok, %__MODULE__{uri: uri, epoch: nil, status: :active, reason: nil}}
  end

  def decode(_), do: {:error, :orchestrator_binding_absent}

  @doc "Return the current active binding or a diagnostic lifecycle error."
  @spec current(map()) :: {:ok, t()} | {:error, term()}
  def current(working_copy) when is_map(working_copy) do
    current_epoch =
      Map.get(working_copy, :orchestrator_materialization_epoch) ||
        Map.get(working_copy, "orchestrator_materialization_epoch")

    with {:ok, binding} <-
           decode(
             Map.get(working_copy, :orchestrator_uri) || Map.get(working_copy, "orchestrator_uri")
           ),
         :ok <- epoch_current(binding, current_epoch),
         :ok <- active(binding) do
      {:ok, binding}
    end
  end

  @doc "Return a binding whose URI matches `uri`, including stale/tombstone values."
  @spec matching(map(), URI.t()) :: {:ok, t()} | :error
  def matching(working_copy, %URI{} = uri) when is_map(working_copy) do
    with {:ok, binding} <-
           decode(
             Map.get(working_copy, :orchestrator_uri) || Map.get(working_copy, "orchestrator_uri")
           ),
         true <- URI.to_string(binding.uri) == URI.to_string(uri) do
      {:ok, binding}
    else
      _ -> :error
    end
  end

  defp validate(%__MODULE__{uri: %URI{}, status: status} = binding)
       when status in [:active, :tombstone],
       do: {:ok, binding}

  defp validate(_), do: {:error, :invalid_orchestrator_binding}

  defp epoch_current(%__MODULE__{epoch: epoch}, epoch) when is_binary(epoch), do: :ok

  defp epoch_current(%__MODULE__{epoch: binding_epoch}, current_epoch) do
    {:error, {:orchestrator_binding_epoch_mismatch, binding_epoch, current_epoch}}
  end

  defp active(%__MODULE__{status: :active}), do: :ok

  defp active(%__MODULE__{status: :tombstone, reason: reason}) do
    {:error, {:orchestrator_binding_tombstoned, reason}}
  end

  defp normalize_status("active"), do: :active
  defp normalize_status("tombstone"), do: :tombstone
  defp normalize_status(status), do: status
end
