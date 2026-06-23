defmodule Ezagent.Email.Inbound.Guard do
  @moduledoc """
  Pure inbound-email guards for the email ExternalMirror poller (#88 PR-2 /
  SPEC §4.5 / §7 / BLOCKER 2 / MED 8). No I/O — every function is a pure
  predicate over a CF-Worker inbox record map (string keys, the §4.5a shape).

  Two responsibilities:

  - **Loop / bounce / auto-response guard (`accept_for_injection?/1`)** — the
    `_email_origin` self-echo skip alone is INSUFFICIENT: a bounce (NDR) or
    auto-reply re-enters as FRESH inbound from a different envelope without
    our origin flag. Reject (the poller then `DELETE`s without injecting) when
    ANY of: `Auto-Submitted` present and not `no`; `Precedence` is
    `bulk`/`auto_reply`/`list`; the envelope-from (`returnPath`) is empty
    (`<>` — the RFC bounce marker); or no usable `Message-ID`.

  - **Authentication enforcement (`authenticated?/2`)** — accept ONLY if the
    captured `Authentication-Results` shows SPF/DKIM/DMARC PASS for the
    `From:` domain AND the `From:` equals the bound, verified `target_id`.
    NO degrade-to-allow: a missing auth verdict or a forged `From` (fails
    DMARC) is rejected.
  """

  @bad_precedence ~w(bulk auto_reply list)

  @doc """
  Should this inbound record be injected at all (loop/bounce/auto guard)?
  Returns `:ok` or `{:reject, reason}` (the poller `DELETE`s on reject).
  Checked FIRST so a bounce of our own outbound never re-enters as fresh
  inbound.
  """
  @spec accept_for_injection?(map()) :: :ok | {:reject, atom()}
  def accept_for_injection?(rec) when is_map(rec) do
    cond do
      bounce_envelope?(rec) -> {:reject, :bounce}
      auto_submitted?(rec) -> {:reject, :auto_submitted}
      bulk_precedence?(rec) -> {:reject, :bulk_precedence}
      no_message_id?(rec) -> {:reject, :no_message_id}
      true -> :ok
    end
  end

  @doc """
  Is the record authenticated for the bound `target_id`? Requires SPF/DKIM/
  DMARC PASS AND `From == target_id`. Returns `:ok` or `{:reject, reason}`.
  """
  @spec authenticated?(map(), String.t()) :: :ok | {:reject, atom()}
  def authenticated?(rec, target_id) when is_map(rec) and is_binary(target_id) do
    cond do
      not from_matches?(rec, target_id) -> {:reject, :from_mismatch}
      not dmarc_pass?(rec) -> {:reject, :auth_failed}
      true -> :ok
    end
  end

  # ----- loop / bounce internals ---------------------------------------------

  # Empty envelope-from (`<>` or "") is the RFC 5321 bounce/NDR marker.
  defp bounce_envelope?(rec) do
    case get(rec, "returnPath") do
      nil -> false
      "" -> true
      "<>" -> true
      v when is_binary(v) -> String.trim(v) in ["", "<>"]
      _ -> false
    end
  end

  # RFC 3834: Auto-Submitted present and not exactly "no" → auto-generated.
  defp auto_submitted?(rec) do
    case get(rec, "autoSubmitted") do
      nil -> false
      "" -> false
      v when is_binary(v) -> String.downcase(String.trim(v)) != "no"
      _ -> false
    end
  end

  defp bulk_precedence?(rec) do
    case get(rec, "precedence") do
      v when is_binary(v) -> String.downcase(String.trim(v)) in @bad_precedence
      _ -> false
    end
  end

  defp no_message_id?(rec) do
    case get(rec, "messageId") do
      v when is_binary(v) -> String.trim(v) == ""
      _ -> true
    end
  end

  # ----- auth internals ------------------------------------------------------

  # `From:` exact-match against the bound verified address. Tolerates a
  # `"Display Name <addr>"` form by extracting the bracketed address.
  defp from_matches?(rec, target_id) do
    from = get(rec, "from") || ""
    extract_address(from) == String.downcase(String.trim(target_id))
  end

  # Parse the captured Authentication-Results header for DMARC=pass AND
  # (SPF=pass OR DKIM=pass). DMARC alone subsumes alignment, but we require
  # the underlying mechanism to have passed too (defence in depth, SPEC §4.5).
  defp dmarc_pass?(rec) do
    ar = get(rec, "authResults") || ""
    ar_down = String.downcase(ar)
    dmarc_pass = verdict(ar_down, "dmarc") == "pass"
    spf_or_dkim = verdict(ar_down, "spf") == "pass" or verdict(ar_down, "dkim") == "pass"
    dmarc_pass and spf_or_dkim
  end

  # Extract `<mechanism>=<verdict>` from an Authentication-Results string.
  # Returns the verdict ("pass" / "fail" / ...) or nil.
  defp verdict(ar_down, mechanism) when is_binary(ar_down) do
    case Regex.run(~r/#{mechanism}=([a-z]+)/, ar_down) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp extract_address(from) when is_binary(from) do
    addr =
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, a] -> a
        _ -> from
      end

    addr |> String.trim() |> String.downcase()
  end

  # CF-Worker records are JSON-decoded → string keys. (Never
  # `String.to_atom` on a key — the atom table is global/unbounded.)
  defp get(rec, key) when is_binary(key), do: Map.get(rec, key)
end
