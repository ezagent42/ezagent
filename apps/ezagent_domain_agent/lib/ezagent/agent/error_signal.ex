defmodule Ezagent.Agent.ErrorSignal do
  @moduledoc """
  Structured wire form for ASYNC agent-reply errors (G5 source 2).

  When an agent fails while generating a reply, the inbound dispatch has
  already returned `:ok` — the failure can only travel back to the user as
  DATA on the reply message itself. This module owns that wire shape: the
  raw error `reason` term is encoded JSON-safe under the reply body's
  `error` key, plus a uniform minimal fallback `text` for degraded surfaces
  (external mirrors — feishu/email — which render text only; an empty text
  there would be a silent drop).

  The render side (world) decodes the payload back into `{:error, reason}`
  and feeds the SAME shared error pipeline the sync dispatch path uses
  (`Ezagent.World.ErrorMatcher` → `Ezagent.World.ErrorRenderer`) —
  per-viewer, at read time. This module NEVER renders: Layer 1/2/3 depends
  on WHO is looking, and domain code never references world modules
  (P9/P12). Agents emit pure reason data; no hand-written error prose.

  ## Wire shape

      encode({:no_api_key, "anthropic"})
      #=> %{"reason" => ["no_api_key", "anthropic"]}

      encode(:sdk_sidecar_timeout)
      #=> %{"reason" => ["sdk_sidecar_timeout"]}

  The list head is the reason tag (an atom in code, a string on the wire);
  the tail holds the reason tuple's args — kept as-is when JSON-safe
  (string/number/boolean/nil), `inspect`ed (and truncated) otherwise.
  `decode/1` restores the head via `String.to_existing_atom/1` (never mints
  atoms) and leaves args as decoded — so error-code triggers should pin only
  the tag and use `:_` wildcards (or JSON-safe literals) for args, which is
  what the batch-1 registry already does (`{:no_api_key, :_}`).

  Message bodies come back string-keyed after a `MessageStore` round-trip
  but atom-keyed over in-process delivery; extracting the payload from the
  body (`error` vs `:error`) is the reader's job — `decode/1` takes the
  already-extracted payload map.
  """

  # Tag used when a reason is not an atom-headed tuple/atom (kept as a
  # module attribute so the atom exists for `String.to_existing_atom/1`).
  @fallback_tag :agent_error

  # Cap inspected args so a huge upstream body (e.g. an HTML error page in
  # `{:http, 500, body}`) never bloats every persisted reply message.
  @max_arg_length 500

  @doc """
  The complete structured-error reply body: uniform fallback `text`,
  the encoded `error` payload, empty `attachments`.
  """
  @spec reply_body(term()) :: map()
  def reply_body(reason) do
    %{text: fallback_text(reason), error: encode(reason), attachments: []}
  end

  @doc "Encode an error reason term into its JSON-safe wire map."
  @spec encode(term()) :: map()
  def encode(reason), do: %{"reason" => encode_reason(reason)}

  @doc """
  Decode a wire map produced by `encode/1` back into the reason term.

  Returns `:error` when the payload is malformed or the tag atom does not
  exist in the running system (readers still render the generic Layer 3
  card in that case — a decode failure is never a silent drop).
  """
  @spec decode(term()) :: {:ok, term()} | :error
  def decode(%{"reason" => [head | rest]}) when is_binary(head) do
    tag = String.to_existing_atom(head)

    case rest do
      [] -> {:ok, tag}
      args -> {:ok, List.to_tuple([tag | args])}
    end
  rescue
    ArgumentError -> :error
  end

  def decode(_), do: :error

  @doc """
  Uniform minimal degraded-surface text (`"[agent error] <tag>"`). NOT the
  user-facing rendering — that is the world-side per-viewer card.
  """
  @spec fallback_text(term()) :: String.t()
  def fallback_text(reason), do: "[agent error] #{reason_tag(reason)}"

  defp reason_tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_tag(reason) when is_tuple(reason) and tuple_size(reason) >= 1 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      _ -> Atom.to_string(@fallback_tag)
    end
  end

  defp reason_tag(_), do: Atom.to_string(@fallback_tag)

  defp encode_reason(reason) when is_atom(reason), do: [Atom.to_string(reason)]

  defp encode_reason(reason) when is_tuple(reason) and tuple_size(reason) >= 1 do
    case Tuple.to_list(reason) do
      [head | rest] when is_atom(head) ->
        [Atom.to_string(head) | Enum.map(rest, &encode_arg/1)]

      _ ->
        [Atom.to_string(@fallback_tag), encode_arg(reason)]
    end
  end

  defp encode_reason(reason), do: [Atom.to_string(@fallback_tag), encode_arg(reason)]

  defp encode_arg(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp encode_arg(v) when is_binary(v), do: truncate(if String.valid?(v), do: v, else: inspect(v))
  defp encode_arg(v) when is_atom(v), do: Atom.to_string(v)
  defp encode_arg(v), do: truncate(inspect(v))

  defp truncate(s) when byte_size(s) <= @max_arg_length, do: s

  defp truncate(s) do
    # `String.slice` keeps the cut on a codepoint boundary (never invalid UTF-8).
    String.slice(s, 0, @max_arg_length) <> "…"
  end
end
