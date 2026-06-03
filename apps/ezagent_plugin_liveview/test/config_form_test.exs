defmodule EzagentPluginLiveview.ConfigFormTest do
  @moduledoc """
  #18 — per-flavor config form surface ("config_surface :form" V2).

  Pure render tests for `ConfigForm` — the Layer-2 component that turns a
  flavor's `Ezagent.UI.Form.form_fields/0` schema into operator-facing
  inputs. The contract under test:

  - the RIGHT fields render per flavor (cc ≠ codex ≠ curl) — divergence is
    driven entirely by each flavor's `form_fields/0`, not by this component;
  - field TYPE drives the rendered control (`:select` → `<option>`s,
    `:path`/`:uri` → monospace input);
  - inputs are namespaced by `name_prefix`;
  - `values` pre-fills inputs (edit mode);
  - an unknown flavor / a Class without the form behaviour renders an
    explicit unavailable hint, never guessed fields.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentPluginLiveview.ConfigForm

  defp render_fields(fields, opts \\ []) do
    assigns = %{
      fields: fields,
      name_prefix: Keyword.get(opts, :name_prefix, "cfg"),
      values: Keyword.get(opts, :values, %{})
    }

    rendered_to_string(~H"""
    <ConfigForm.config_fields
      fields={@fields}
      name_prefix={@name_prefix}
      values={@values}
    />
    """)
  end

  defp render_flavor(flavor, opts \\ []) do
    assigns = %{
      flavor: flavor,
      name_prefix: Keyword.get(opts, :name_prefix, "cfg"),
      values: Keyword.get(opts, :values, %{})
    }

    rendered_to_string(~H"""
    <ConfigForm.flavor_config_fields
      flavor={@flavor}
      name_prefix={@name_prefix}
      values={@values}
    />
    """)
  end

  describe "config_fields/1 — field-type → control mapping" do
    test ":text renders a plain text input (no font-mono)" do
      html =
        render_fields([%{name: "model", type: :text, label: "Model", placeholder: "gpt"}])

      assert html =~ ~s(name="cfg[model]")
      assert html =~ ~s(placeholder="gpt")
      assert html =~ ~s(data-config-field="model")
      # plain text fields are NOT monospaced
      refute monospace_input?(html, "cfg[model]")
    end

    test ":path renders a monospace input + filesystem hint" do
      html = render_fields([%{name: "cwd", type: :path, label: "Working dir"}])

      assert html =~ ~s(name="cfg[cwd]")
      assert monospace_input?(html, "cfg[cwd]")
      assert html =~ "Filesystem path"
    end

    test ":uri renders a monospace input" do
      html = render_fields([%{name: "agent_uri", type: :uri, label: "Agent URI"}])

      assert html =~ ~s(name="cfg[agent_uri]")
      assert monospace_input?(html, "cfg[agent_uri]")
    end

    test ":select renders a dropdown with every option" do
      html =
        render_fields([
          %{name: "policy", type: :select, label: "Policy", options: ["a", "b", "c"]}
        ])

      assert html =~ "<select"
      assert html =~ ~s(name="cfg[policy]")
      assert html =~ ~s(value="a")
      assert html =~ ~s(value="b")
      assert html =~ ~s(value="c")
    end

    test "required fields are marked with an asterisk" do
      html = render_fields([%{name: "x", type: :text, label: "Ex", required: true}])
      assert html =~ "Ex *"
    end

    test "name_prefix namespaces every input" do
      html =
        render_fields(
          [%{name: "model", type: :text, label: "Model"}],
          name_prefix: "agent_config"
        )

      assert html =~ ~s(name="agent_config[model]")
      refute html =~ ~s(name="cfg[model]")
    end

    test "values pre-fill inputs (edit mode); default is the fallback" do
      html =
        render_fields(
          [
            %{name: "model", type: :text, label: "Model"},
            %{name: "policy", type: :select, label: "Policy", options: ["", "x"], default: ""}
          ],
          values: %{"model" => "deepseek-chat"}
        )

      assert html =~ ~s(value="deepseek-chat")
    end

    test "select pre-selects the current value" do
      html =
        render_fields(
          [%{name: "policy", type: :select, label: "Policy", options: ["a", "b"]}],
          values: %{"policy" => "b"}
        )

      # the matching option carries `selected`
      assert html =~ ~r/<option[^>]*value="b"[^>]*selected/
    end
  end

  describe "flavor_config_fields/1 — per-flavor divergence (cc ≠ codex ≠ curl)" do
    test "cc renders exactly its two fields and no codex-only fields" do
      html = render_flavor("cc")

      assert html =~ ~s(data-config-field="agent_uri")
      assert html =~ ~s(data-config-field="cwd")
      # cc has NO model / approval_policy / sandbox fields
      refute html =~ ~s(data-config-field="model")
      refute html =~ ~s(data-config-field="approval_policy")
      refute html =~ ~s(data-config-field="sandbox")
    end

    test "codex renders its select fields (approval_policy + sandbox options)" do
      html = render_flavor("codex")

      assert html =~ ~s(data-config-field="agent_uri")
      assert html =~ ~s(data-config-field="approval_policy")
      assert html =~ ~s(data-config-field="sandbox")
      # the actual codex option values prove these are codex's own fields
      assert html =~ ~s(value="on-request")
      assert html =~ ~s(value="workspace-write")
      assert html =~ ~s(value="danger-full-access")
    end

    test "curl renders its provider / api_url / model fields" do
      html = render_flavor("curl")

      assert html =~ ~s(data-config-field="provider")
      assert html =~ ~s(data-config-field="api_url")
      assert html =~ ~s(data-config-field="model")
    end

    test "cc and codex produce DIFFERENT field sets (divergence is real)" do
      cc = render_flavor("cc")
      codex = render_flavor("codex")
      refute cc == codex
    end

    test "unknown flavor renders an explicit unavailable hint, not guessed fields" do
      html = render_flavor("does-not-exist")

      assert html =~ ~s(data-config-form-unavailable="unknown_flavor")
      refute html =~ "data-config-field"
    end
  end

  # An input is monospace iff its tag carries the `font-mono` class. Pull
  # the tag for `name=` and check it.
  defp monospace_input?(html, name) do
    case Regex.run(~r/<(?:input|select)[^>]*name="#{Regex.escape(name)}"[^>]*>/, html) do
      [tag] -> tag =~ "font-mono"
      _ -> false
    end
  end
end
