defmodule EzagentPluginFeishu.SourceInvariants.DispatchOnlySeedTest do
  @moduledoc """
  Handoff B1 Phase 5 — narrow source invariant: the Feishu user-binding
  seed pipeline (Application after_boot, UserBindingSeed importer,
  DispatchAdapter, and the three legacy mix wrappers) MUST NOT call raw
  storage (`EzagentPluginFeishu.UserBinding.*`), raw policy
  (`EzagentPluginFeishu.BindingPolicy.apply/2`), or raw handler
  (`EzagentPluginFeishu.Behavior.UserBinding.handle_*`) directly.

  Every mutation goes through `Ezagent.Invocation.dispatch/1`.

  This is a NARROW invariant — it does NOT forbid these calls in:
  - The formal Behavior itself (`behavior/user_binding.ex`) — it IS the
    handler, and it MUST call storage/policy internally.
  - Storage tests (`test/ezagent/user_binding_test.exs`) — they test
    the storage module directly.
  - The B2 World files — those are not this handoff's scope.

  The invariant is checked by grep — scan the producer files and assert
  they contain zero disallowed imports/calls.
  """
  use ExUnit.Case, async: true

  @producer_files [
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/parser.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/dispatch_adapter.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.bind.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.unbind.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.list.ex"
  ]

  # The three named modules that producer files must never call directly.
  # Storage: match actual CALLS (not mere mentions in moduledoc prose).
  # No exceptions — every producer file goes through the executor function
  # port or dispatch.
  @forbidden_raw_storage ~r/\bUserBinding\.(bind|unbind|resolve|list_all|open_ids_for)\b/
  # Policy (direct apply):
  @forbidden_raw_policy ~r/\bBindingPolicy\.apply\b/
  # Raw handler:
  @forbidden_raw_handler ~r/\bBV\.handle_|\bBehavior\.UserBinding\.handle_/

  defp repo_root, do: Path.expand("../../../..", __DIR__)

  # Pre-filter: exclude lines that are moduledoc prose or comments
  # (the `>` marker, backtick code-refs in docs, and `#`-prefixed comments).
  defp code_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "#") or
        String.starts_with?(trimmed, ">") or
        String.contains?(trimmed, "`UserBinding") or
        String.contains?(trimmed, "`BindingPolicy")
    end)
    |> Enum.with_index(1)
  end

  test "producer files never call raw storge (EzagentPluginFeishu.UserBinding)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      assert File.exists?(path), "invariant producer file missing: #{file}"

      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_storage)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls raw EzagentPluginFeishu.UserBinding directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files never call raw policy (EzagentPluginFeishu.BindingPolicy.apply)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_policy)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls BindingPolicy.apply directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files never call raw handler (Behavior.UserBinding.handle_*)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_handler)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls Behavior.UserBinding.handle_* directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files go through function port or dispatch" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)

      # Parser is a pure module — no executor needed.
      # Legacy CLI tasks are args-only — no dispatch at all.
      if String.contains?(path, "application.ex") or
           String.contains?(path, "user_binding_seed.ex") or
           String.contains?(path, "dispatch_adapter.ex") do
        content = File.read!(path)

        has_executor_or_dispatch =
          String.contains?(content, "executor_port") or
            String.contains?(content, "Invocation.dispatch") or
            String.contains?(content, "DispatchAdapter")

        assert has_executor_or_dispatch,
               "#{file} lacks function-port/dispatch wiring"
      end
    end
  end
end
