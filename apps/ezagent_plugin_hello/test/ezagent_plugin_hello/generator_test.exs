defmodule EzagentPluginHello.GeneratorTest do
  # async: false — the backend-routing test mutates the HELLO_LLM_BACKEND env var,
  # which is process-global; keep it off the shared async pool.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EzagentPluginHello.Generator

  # INV-CC ① — with HELLO_LLM_BACKEND=claude_code, call_llm/3 MUST take the
  # ClaudeCode.chat path and NEVER touch the curl "llm" member (Members.role_uri /
  # AgentBridge.complete). Both branches degrade classify_intent to :builder on
  # error, so the RETURN value alone can't tell them apart — but the error TAG the
  # failure carries can: the claude_code branch surfaces a `:claude_*` tag (it ran
  # the external CLI), while the HTTP branch on an unresolvable session would
  # surface `:no_llm_agent` (Members.role_uri → :error). We run against a session
  # URI with NO live Kind and assert the logged failure is the claude_code tag and
  # NEVER `:no_llm_agent` — proving Members/AgentBridge were not consulted.
  describe "call_llm backend routing (INV-CC ①)" do
    setup do
      prev_backend = System.get_env("HELLO_LLM_BACKEND")
      prev_bin = System.get_env("HELLO_CLAUDE_BIN")

      on_exit(fn ->
        restore_env("HELLO_LLM_BACKEND", prev_backend)
        restore_env("HELLO_CLAUDE_BIN", prev_bin)
      end)

      :ok
    end

    test "claude_code backend takes the ClaudeCode path, never the curl member" do
      System.put_env("HELLO_LLM_BACKEND", "claude_code")
      # Point at a bogus binary so the CLI attempt fails fast (no real generation)
      # while STILL exercising the claude_code branch end to end.
      System.put_env("HELLO_CLAUDE_BIN", "/nonexistent/hello-claude-bin")

      # A session URI with NO live Kind. If the HTTP branch ran instead, call_llm
      # would consult Members.role_uri(session, "llm") on this dead URI and the
      # failure tag would be :no_llm_agent.
      session = Ezagent.URI.session("system", :hello, "inv-cc-claude-code")

      log =
        capture_log(fn ->
          assert Generator.classify_intent(session, "make the hero bigger") == :builder
        end)

      # The failure came from the claude_code branch (ran the CLI) …
      assert log =~ "claude"
      # … and NOT from the HTTP branch (which never ran — no member lookup).
      refute log =~ "no_llm_agent"
    end

    test "classify_intent/2 remains a public arity-2 function" do
      assert function_exported?(Generator, :classify_intent, 2)
    end

    defp restore_env(key, nil), do: System.delete_env(key)
    defp restore_env(key, val), do: System.put_env(key, val)
  end

  # The incremental-edit core: nodes are id-annotated (pre-order), the model emits
  # ops referencing those ids, and `apply_patch/2` applies them. These pin the
  # patch semantics so "change one button's text" stays a one-op edit, not a full
  # page regeneration.
  describe "apply_patch/2 — incremental edit ops" do
    setup do
      page = %{
        "type" => "Stack",
        "props" => %{"direction" => "vertical", "className" => "page-root"},
        "children" => [
          %{
            "type" => "Heading",
            "props" => %{"text" => "Old title", "level" => 1},
            "children" => []
          },
          %{
            "type" => "Stack",
            "props" => %{"className" => "cta"},
            "children" => [
              %{"type" => "Button", "props" => %{"label" => "Buy"}, "children" => []}
            ]
          }
        ]
      }

      # ids are assigned pre-order: root=n0, Heading=n1, inner Stack=n2, Button=n3.
      %{page: page}
    end

    test "set merges props on the addressed node, leaving the rest untouched", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n1", "props" => %{"text" => "New title"}}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "New title"
      # level preserved (merge, not replace); the rest of the tree unchanged.
      assert get_in(patched, ["children", Access.at(0), "props", "level"]) == 1

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "Buy"

      # ids are stripped from the result.
      refute Map.has_key?(patched, "id")
    end

    test "set reaches a deeply nested node by id", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n3", "props" => %{"label" => "Start free"}}
        ])

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "Start free"
    end

    test "replace swaps the whole node", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{
            "op" => "replace",
            "id" => "n1",
            "node" => %{"type" => "Text", "props" => %{"text" => "Hi"}, "children" => []}
          }
        ])

      assert get_in(patched, ["children", Access.at(0), "type"]) == "Text"
    end

    test "insert adds a child at the parent (append when no index)", %{page: page} do
      new = %{"type" => "Text", "props" => %{"text" => "Sub"}, "children" => []}

      patched =
        Generator.apply_patch(page, [%{"op" => "insert", "parent" => "n0", "node" => new}])

      kids = patched["children"]
      assert length(kids) == 3
      assert List.last(kids)["props"]["text"] == "Sub"
    end

    test "insert honors an explicit index", %{page: page} do
      new = %{"type" => "Text", "props" => %{"text" => "First"}, "children" => []}

      patched =
        Generator.apply_patch(page, [
          %{"op" => "insert", "parent" => "n0", "index" => 0, "node" => new}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "First"
    end

    test "remove deletes the addressed node", %{page: page} do
      patched = Generator.apply_patch(page, [%{"op" => "remove", "id" => "n1"}])

      types = Enum.map(patched["children"], & &1["type"])
      refute "Heading" in types
      assert "Stack" in types
    end

    test "an unknown op is a no-op (degrade, never crash)", %{page: page} do
      patched = Generator.apply_patch(page, [%{"op" => "frobnicate", "id" => "n1"}])
      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "Old title"
    end

    test "multiple ops apply in order", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n1", "props" => %{"text" => "T2"}},
          %{"op" => "set", "id" => "n3", "props" => %{"label" => "L2"}}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "T2"

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "L2"
    end
  end
end
