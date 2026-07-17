defmodule Ezagent.World.ErrorMatcher do
  @moduledoc """
  Matches an `{:error, reason}` against the registered error code table.

  Returns the matching `%ErrorCode{}` entry or `nil` if no code is registered
  for this error pattern. A `nil` return triggers Layer 3 fallback — the
  generic error message + automatic issue registration.
  """

  alias Ezagent.World.ErrorCode

  @doc """
  Matches a dispatch result against the error code registry.

  Returns the matching `ErrorCode.t()` or `nil`.

  ## Examples

      iex> match({:error, :unauthorized})
      %{code: "action_unauthorized", ...}

      iex> match({:error, {:no_api_key, "anthropic"}})
      %{code: "agent_credential_missing", ...}

      iex> match({:error, :some_unregistered_error})
      nil
  """
  @spec match(term()) :: ErrorCode.t() | nil
  def match({:error, reason}) do
    ErrorCode.all()
    |> Enum.find(fn entry ->
      trigger_matches?(entry.trigger, reason)
    end)
  end

  def match(_other), do: nil

  @doc false
  def trigger_matches?({:error, pattern}, reason) when is_tuple(pattern) do
    tuple_pattern_match?(pattern, reason, tuple_size(pattern))
  end

  def trigger_matches?({:error, pattern}, reason) when is_atom(pattern) do
    pattern == reason
  end

  # pattern is `{:no_api_key, _}` — matches `{:no_api_key, "anthropic"}`
  defp tuple_pattern_match?(pattern, reason, size) when is_tuple(reason) and tuple_size(reason) == size do
    pattern
    |> Tuple.to_list()
    |> Enum.zip(Tuple.to_list(reason))
    |> Enum.all?(fn
      {:_, _} -> true
      {p, r} -> p == r
    end)
  end

  defp tuple_pattern_match?(_pattern, _reason, _size), do: false
end
