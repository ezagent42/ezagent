defmodule Ezagent.AgentBridge.AttachmentNormalizer do
  @moduledoc """
  Shared attachment-key normalization for AgentBridge flavor adapters.

  The bridge clients (cc / codex sidecars) send attachment maps with
  STRING keys (`"type"` / `"local_path"` / `"name"`) and a string `"type"`
  value (`"image"` / `"file"` / …). The downstream `Ezagent.Message` body
  expects ATOM keys + atom type values. Every flavor adapter ran the same
  byte-identical normalization; Cleanup-2 lifts it here — both plugins
  already depend on `ezagent_domain_agent_bridge` (they `@behaviour`
  `Ezagent.AgentBridge.Adapter`), so this is a core-of-the-feature shared
  helper, never a cross-plugin import (plugin isolation preserved).
  """

  @attachment_key_atoms %{
    "type" => :type,
    "local_path" => :local_path,
    "name" => :name
  }

  @attachment_type_atoms %{
    "image" => :image,
    "file" => :file,
    "audio" => :audio,
    "video" => :video,
    "media" => :media
  }

  @doc """
  Normalize a list of attachment maps, converting string keys/type values
  to atoms. Non-map list entries pass through unchanged.
  """
  @spec normalize_attachments(list()) :: list()
  def normalize_attachments(list) when is_list(list) do
    Enum.map(list, fn
      %{} = m -> normalize_attachment_keys(m)
      other -> other
    end)
  end

  @doc """
  Normalize a single attachment map's keys (and the `"type"` value).
  """
  @spec normalize_attachment_keys(map()) :: map()
  def normalize_attachment_keys(m) do
    Enum.into(m, %{}, fn
      {k, v} when is_binary(k) ->
        {Map.get(@attachment_key_atoms, k, k), normalize_attachment_value(k, v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp normalize_attachment_value("type", v) when is_binary(v),
    do: Map.get(@attachment_type_atoms, v, v)

  defp normalize_attachment_value(_, v), do: v
end
