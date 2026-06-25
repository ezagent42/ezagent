defmodule Ezagent.Plugin.ConfigSurface do
  @moduledoc """
  Runtime validation for a plugin's `config_surface/0` declaration.

  Extracted from `Ezagent.Plugin` (df-tech kanban-clean cohesive split,
  mirroring the 2026-06-23 >1000-LOC burn-down extractions) so the
  contract module stays under the architecture LOC budget. The single
  caller is `Ezagent.Plugin`'s `publish/1`; behaviour and error messages
  are byte-for-byte the prior inline `assert_config_surface!/2`.
  """

  @doc """
  Assert a `config_surface/0` value is a valid V1 surface, raising
  `ArgumentError` (naming the plugin) otherwise.

  V1 is `:route | :flavor | nil` (codex PR-5 MEDIUM-5). `:form`
  (auto-rendered settings persisted to a store that does not exist yet)
  is V2 — rejected. Any other shape is malformed and rejected so it
  cannot reach `plugins_live` and crash `/plugins`. Mirrors the
  `:ezagent_plugin_check` gate's compile-time check.
  """
  @spec assert!(module(), Ezagent.Plugin.config_surface()) :: :ok
  def assert!(_plugin_module, nil), do: :ok

  def assert!(_plugin_module, %{kind: :route, path: path, label: label})
      when is_binary(path) and is_binary(label),
      do: :ok

  def assert!(_plugin_module, %{kind: :flavor, flavor: flavor, label: label})
      when is_binary(flavor) and is_binary(label),
      do: :ok

  def assert!(plugin_module, %{kind: :form} = surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a `:form` config_surface/0 " <>
            "(#{inspect(surface)}). The plugin settings store is V2 — `:form` " <>
            "is rejected in V1. V1 config_surface/0 is :route | :flavor | nil " <>
            "(SPEC §6.1)."
  end

  def assert!(plugin_module, surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a malformed config_surface/0: " <>
            "#{inspect(surface)}. V1 config_surface/0 is one of " <>
            "%{kind: :route, path: String.t(), label: String.t()}, " <>
            "%{kind: :flavor, flavor: String.t(), label: String.t()}, or nil " <>
            "(SPEC §6.1)."
  end
end
