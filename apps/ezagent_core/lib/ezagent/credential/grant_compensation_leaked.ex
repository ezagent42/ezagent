defmodule Ezagent.Credential.GrantCompensationLeaked do
  @moduledoc """
  #201-cred (codex r3 NEW-HIGH-1) — raised when a post-mint RAISE could NOT be
  compensated: the just-minted credential grant may remain durable.

  The pre-r3 boundaries discarded the compensation result with `_ =` and
  re-raised ONLY the original exception, so an exhausted compensation
  (`{:error, :grant_compensation_failed}`) silently left the grant durable while
  the spawn aborted. This exception WRAPS the original error (preserving the
  original stacktrace via `reraise`) so the abort surfaces the leak LOUDLY —
  `GrantMint.compensate/3` already logged it `:critical`; this makes it part of
  the propagated failure the caller sees.

  It is only ever raised on the compensation-FAILURE path. When compensation
  succeeds, the original exception is re-raised unchanged.
  """
  defexception [:message, :original, :agent_uri, :incarnation_id]

  @type t :: %__MODULE__{
          message: String.t(),
          original: term(),
          agent_uri: String.t(),
          incarnation_id: String.t()
        }

  @doc "Wrap the original error with the leaked-grant context."
  @spec wrap(String.t(), String.t(), term()) :: t()
  def wrap(agent_uri_str, incarnation_id, original)
      when is_binary(agent_uri_str) and is_binary(incarnation_id) do
    %__MODULE__{
      agent_uri: agent_uri_str,
      incarnation_id: incarnation_id,
      original: original,
      message:
        "credential grant compensation FAILED after a post-mint raise; the minted " <>
          "grant may remain durable (agent_uri=#{agent_uri_str} " <>
          "incarnation_id=#{incarnation_id}); original error: #{format_original(original)}"
    }
  end

  defp format_original(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_original(other), do: inspect(other)
end
