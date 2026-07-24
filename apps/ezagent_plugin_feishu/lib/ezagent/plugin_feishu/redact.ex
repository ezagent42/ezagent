defmodule EzagentPluginFeishu.Redact do
  @moduledoc """
  Shared log-redaction helper for the Feishu user-binding seed pipeline.

  Locked Decision #12 (handoff B1): seed/import/rollback shared logs must
  never contain a full open_id or user URI — only a line/row number,
  workspace, a short fingerprint, and a stable error code. `fingerprint/1`
  is that short, non-reversible correlation token.
  """

  @fingerprint_bytes 4

  @doc "Short, deterministic, non-reversible correlation token for a raw value."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> binary_part(0, @fingerprint_bytes)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Safe, redacted description of a UserBindingSeed error tuple.

  Never includes full open_ids, user URIs, or raw dispatch reasons.
  Only row numbers, workspace names, fingerprints, and stable error atoms.
  """
  @spec describe(term()) :: String.t()
  def describe({:dispatch_failed, row, ws, fp, _reason}) do
    "dispatch failed at row #{row} workspace #{ws} fingerprint=#{fp}"
  end

  def describe({:cross_workspace_conflict, row, fp, ws}) do
    "cross-workspace conflict at row #{row} workspace #{ws} fingerprint=#{fp}"
  end

  def describe({:conflict, row, ws, fp}) do
    "conflict at row #{row} workspace #{ws} fingerprint=#{fp}"
  end

  def describe({:preflight_read_failed, ws, _reason}) do
    "preflight read failed workspace #{ws}"
  end

  def describe({:malformed_yaml, _reason}) do
    "malformed YAML"
  end

  def describe({:invalid_shape, msg}) when is_binary(msg) do
    "invalid shape: #{msg}"
  end

  def describe({:invalid_row, row, _reason}) do
    "invalid row #{row}"
  end

  def describe({:duplicate_open_id, fp, rows}) do
    "duplicate open_id fingerprint=#{fp} at rows #{length(rows)}"
  end

  def describe({:file_read_error, _reason}) do
    "file read error"
  end

  # Fail-closed: unknown error shapes get a generic message, never raw
  # term inspection (which could leak open_id / user_uri in production).
  def describe(_other) do
    "unexpected seed error"
  end
end
