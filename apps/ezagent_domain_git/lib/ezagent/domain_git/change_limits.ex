defmodule Ezagent.DomainGit.ChangeLimits do
  @moduledoc "Runtime-owned limits for a collection of file changes."

  alias Ezagent.DomainGit.ValidationError

  @fields [:max_files, :max_file_bytes, :max_total_bytes]
  @defaults %{max_files: 100, max_file_bytes: 1_000_000, max_total_bytes: 5_000_000}

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          max_files: pos_integer(),
          max_file_bytes: pos_integer(),
          max_total_bytes: pos_integer()
        }

  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @spec current() :: {:ok, t()} | {:error, :invalid_change_limits_config}
  def current do
    config = Application.get_env(:ezagent_domain_git, :change_limits, @defaults)

    case new(config) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, :invalid_change_limits_config}
    end
  end

  defp validate_values(attrs) do
    case Enum.find(@fields, &(not (is_integer(attrs[&1]) and attrs[&1] > 0))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end
end
