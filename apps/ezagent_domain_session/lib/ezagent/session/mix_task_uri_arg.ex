defmodule Ezagent.Session.MixTaskUriArg do
  @moduledoc false

  # Shared CLI-argument parsing for the operator `mix ezagent.session.*`
  # tasks: a bare positional arg must resolve to a `session://` URI, else the
  # task fails loudly via `Mix.raise/1` rather than continuing against a
  # malformed target. Extracted (PR #1576) from the byte-identical private
  # copies duplicated across `ezagent.session.reinstall_socialware` and the
  # new `ezagent.session.repair_template_config` — a cross-file-duplicate-fn
  # gate hit, not two independently-evolving implementations.

  @doc false
  def parse_session_uri!(str) do
    case Ezagent.URI.parse(String.trim(str)) do
      {:ok, %URI{scheme: "session"} = uri} -> uri
      {:ok, %URI{} = other} -> Mix.raise("not a session URI: #{URI.to_string(other)}")
      _ -> Mix.raise("bad session URI: #{inspect(str)}")
    end
  end
end
