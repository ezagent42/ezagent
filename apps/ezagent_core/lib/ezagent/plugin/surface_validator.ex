defmodule Ezagent.Plugin.SurfaceValidator do
  @moduledoc """
  Boot-time shape gate for a plugin's `config_surface/0` (the `/plugins` config
  icon).

  Extracted from `Ezagent.Plugin.boot/1` so the contract module stays under
  its LOC budget (ARCHITECTURE.md §14 — cohesive extraction precedent). The
  gate mirrors the corresponding compile-time check in the
  `:ezagent_plugin_check` compiler, so a malformed surface is rejected loudly
  at boot rather than silently reaching the world UI and crashing it.

  The Layer-2 nav (`nav_surfaces/0`) and Layer-3 per-session tab
  (`session_tabs/0`) surfaces are deliberately NOT core concerns (2026-06-30) —
  they are a World-side convention owned by `Ezagent.World.UiSurfaceProvider`
  and are shape-checked read-time in world. This module owns only
  `config_surface/0`.
  """

  @doc """
  Validate a plugin's `config_surface/0` shape.

  Called once from `Ezagent.Plugin.boot/1` so the contract module owns no
  per-surface iteration (LOC budget — ARCHITECTURE.md §14). Raises
  `ArgumentError` on a malformed surface.
  """
  @spec validate_surfaces!(module()) :: :ok
  def validate_surfaces!(plugin_module) do
    plugin_module.config_surface()
    |> List.wrap()
    |> Enum.each(&assert_config_surface!(plugin_module, &1))

    :ok
  end

  # --- config_surface/0 (codex PR-5 MEDIUM-5) -----------------------------
  #
  # V1 is `:route | :flavor | nil`. `:form` (auto-rendered settings persisted
  # to a store that does not exist yet) is V2 — reject it. A malformed map is
  # also rejected so it cannot reach `plugins_live` and crash `/plugins`.
  @doc "Validate a plugin's `config_surface/0` (raises `ArgumentError` on a bad shape)."
  @spec assert_config_surface!(module(), Ezagent.Plugin.config_surface()) :: :ok
  def assert_config_surface!(_plugin_module, nil), do: :ok

  def assert_config_surface!(_plugin_module, %{kind: :route, path: path, label: label})
      when is_binary(path) and is_binary(label),
      do: :ok

  def assert_config_surface!(_plugin_module, %{kind: :flavor, flavor: flavor, label: label})
      when is_binary(flavor) and is_binary(label),
      do: :ok

  def assert_config_surface!(plugin_module, %{kind: :form} = surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a `:form` config_surface/0 " <>
            "(#{inspect(surface)}). The plugin settings store is V2 — `:form` " <>
            "is rejected in V1. V1 config_surface/0 is :route | :flavor | nil " <>
            "(SPEC §6.1)."
  end

  def assert_config_surface!(plugin_module, surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a malformed config_surface/0: " <>
            "#{inspect(surface)}. V1 config_surface/0 is one of " <>
            "%{kind: :route, path: String.t(), label: String.t()}, " <>
            "%{kind: :flavor, flavor: String.t(), label: String.t()}, or nil " <>
            "(SPEC §6.1)."
  end
end
