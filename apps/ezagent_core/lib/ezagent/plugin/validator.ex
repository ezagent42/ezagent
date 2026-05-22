defmodule Ezagent.Plugin.Validator do
  @moduledoc """
  Plugin-module-LOCAL `@after_compile` validation for `use Ezagent.Plugin`.

  SPEC §3.1. `use Ezagent.Plugin` injects
  `@after_compile {Ezagent.Plugin.Validator, :__after_compile__}`. This
  runs the instant a plugin module finishes compiling and checks ONLY
  what is local to that module:

  - `plugin_info/0` is implemented;
  - it returns a well-formed `t:Ezagent.Plugin.plugin_info/0` map —
    `slug` a non-empty URL-safe string, `name` / `description` /
    `version` non-empty strings.

  A failure raises `CompileError`, so a malformed plugin fails the
  build the instant its own module compiles — Allen's "没实现接口就报错"
  for the most common mistake.

  ## What it deliberately does NOT do (codex HIGH-3)

  It does **not** dereference declared kind / behavior / template /
  agent-flavor modules. In an umbrella those sibling modules may be
  compiled AFTER this plugin module, so `Code.ensure_compiled/1` on
  them here would be flaky. Those cross-module checks live in the
  `:ezagent_plugin_check` Mix compiler (SPEC §3.2) — it runs after the
  whole `ezagent_plugin_*` app has compiled.
  """

  # A URL-safe slug: lowercase letters, digits, hyphen, underscore.
  # First char must be a letter (so the slug works in a URL path and
  # as a stable identifier).
  @slug_regex ~r/^[a-z][a-z0-9_-]*$/

  @doc """
  `@after_compile` callback. `env` is the compile env, `_bytecode` the
  compiled module's bytecode.

  Raises `CompileError` (with `env.file` / `env.line`) on the first
  local violation found.
  """
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(env, bytecode) do
    module = env.module

    # `@after_compile` runs the instant the module body finishes
    # compiling — the `.beam` may not be loaded into the code server
    # yet, so `function_exported?/3` is unreliable here. Read the
    # export list straight from `bytecode` (the compiled binary the
    # callback is handed) via `:beam_lib`.
    unless exports?(bytecode, :plugin_info, 0) do
      fail!(
        env,
        "#{inspect(module)} uses Ezagent.Plugin but does not implement the " <>
          "required callback plugin_info/0. Define `def plugin_info, do: " <>
          "%{slug: …, name: …, description: …, version: …}`."
      )
    end

    # `plugin_info/0` exists — ensure the module is loadable so we can
    # call it to validate its return value.
    {:module, ^module} = Code.ensure_compiled(module)
    info = module.plugin_info()
    validate_info!(env, module, info)

    :ok
  end

  # Does `bytecode` export `name/arity`? Reads the BEAM `:exports`
  # chunk — works before the module is loaded.
  defp exports?(bytecode, name, arity) do
    case :beam_lib.chunks(bytecode, [:exports]) do
      {:ok, {_module, [exports: exports]}} -> {name, arity} in exports
      _ -> false
    end
  end

  # --- internals --------------------------------------------------------

  defp validate_info!(env, module, info) when is_map(info) do
    validate_slug!(env, module, Map.get(info, :slug))
    validate_string_field!(env, module, info, :name)
    validate_string_field!(env, module, info, :description)
    validate_string_field!(env, module, info, :version)
    :ok
  end

  defp validate_info!(env, module, other) do
    fail!(
      env,
      "#{inspect(module)}.plugin_info/0 must return a map with keys " <>
        ":slug, :name, :description, :version — got #{inspect(other)}."
    )
  end

  defp validate_slug!(env, module, slug) when is_binary(slug) do
    if slug != "" and Regex.match?(@slug_regex, slug) do
      :ok
    else
      fail!(
        env,
        "#{inspect(module)}.plugin_info/0 :slug must be a non-empty URL-safe " <>
          "string matching #{inspect(@slug_regex)} (lowercase letter first, " <>
          "then letters/digits/-/_). Got #{inspect(slug)}."
      )
    end
  end

  defp validate_slug!(env, module, other) do
    fail!(
      env,
      "#{inspect(module)}.plugin_info/0 :slug must be a non-empty URL-safe " <>
        "string. Got #{inspect(other)}."
    )
  end

  defp validate_string_field!(env, module, info, key) do
    case Map.get(info, key) do
      value when is_binary(value) and value != "" ->
        :ok

      other ->
        fail!(
          env,
          "#{inspect(module)}.plugin_info/0 :#{key} must be a non-empty string. " <>
            "Got #{inspect(other)}."
        )
    end
  end

  defp fail!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end
end
