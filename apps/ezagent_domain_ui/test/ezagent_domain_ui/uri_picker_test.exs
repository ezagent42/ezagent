defmodule EzagentDomainUi.UriPickerTest do
  @moduledoc """
  V1 UI PR-1 (SPEC §1.2) — render tests for the `uri_picker/1`
  component, both `:single` (combobox) and `:multi` (tag-input) modes.

  These assert the structural contract the `uri_picker.js` hook + the
  server revalidation depend on: the `phx-hook` mount point, the
  `phx-update="ignore"` mutable subtree, the `data-options` JSON
  attribute, and the hidden form inputs.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import EzagentDomainUi.Primitives

  defp opts do
    [
      %{uri: "entity://team-alpha/agent/cc_demo", label: "CC Demo", kind: :entity, flavor: "cc"},
      %{uri: "entity://team-alpha/user/alice", label: "Alice", kind: :entity, flavor: nil},
      %{uri: "session://system/default/main", label: "main", kind: :session, flavor: nil}
    ]
  end

  describe "uri_picker/1 :single mode" do
    test "renders the phx-hook root + phx-update=ignore subtree + data-options" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="rule[matcher_arg]" mode={:single} options={@options} />
        """)

      assert html =~ ~s(phx-hook="UriPicker")
      assert html =~ ~s(data-mode="single")
      assert html =~ ~s(phx-update="ignore")
      # data-options carries the immutable option list as JSON.
      assert html =~ "data-options="
      assert html =~ "entity://team-alpha/agent/cc_demo"
      assert html =~ "session://system/default/main"
    end

    test "single mode emits one hidden input under the name attr" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker
          name="rule[matcher_arg]"
          mode={:single}
          options={@options}
          value="entity://team-alpha/user/alice"
        />
        """)

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(name="rule[matcher_arg]")
      # The pre-selected value seeds the hidden input.
      assert html =~ ~s(value="entity://team-alpha/user/alice")
      # No list-style name for single mode.
      refute html =~ ~s(name="rule[matcher_arg][]")
    end

    test "renders a label + required marker when given" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="x" mode={:single} options={@options} label="Matcher" required={true} />
        """)

      assert html =~ "Matcher"
      assert html =~ "*"
    end
  end

  describe "uri_picker/1 :multi mode" do
    test "renders chips for pre-selected values with [] hidden inputs" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker
          name="rule[receivers]"
          mode={:multi}
          options={@options}
          value={["entity://team-alpha/agent/cc_demo", "session://system/default/main"]}
        />
        """)

      assert html =~ ~s(data-mode="multi")
      # Multi mode → name[] list-style hidden inputs.
      assert html =~ ~s(name="rule[receivers][]")
      assert html =~ "data-uri-picker-chip"
      assert html =~ "entity://team-alpha/agent/cc_demo"
      assert html =~ "session://system/default/main"
    end

    test "renders no chips when value is empty" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="rule[receivers]" mode={:multi} options={@options} />
        """)

      # The chips container exists, but holds no chip <span>s.
      refute html =~ "data-uri-picker-chip "
      refute html =~ ~s(data-uri-picker-chip>)
      assert html =~ ~s(data-mode="multi")
    end
  end

  describe "uri_picker/1 allow_freetext" do
    test "renders a <details> disclosure with a disabled free-text input" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="x" mode={:single} options={@options} allow_freetext={true} />
        """)

      assert html =~ "<details"
      assert html =~ "data-uri-picker-freetext-input"
      # Disabled by default — the hook enables it when the disclosure opens.
      assert html =~ "disabled"
      assert html =~ "or enter a URI manually"
    end

    test "no <details> when allow_freetext is false (default)" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="x" mode={:single} options={@options} />
        """)

      refute html =~ "data-uri-picker-freetext"
    end
  end

  describe "uri_picker/1 option rendering" do
    test "data-options JSON carries uri/label/kind/flavor for each option" do
      assigns = %{options: opts()}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="x" mode={:single} options={@options} />
        """)

      # The hook reads exactly these 4 keys.
      assert html =~ "&quot;uri&quot;"
      assert html =~ "&quot;label&quot;"
      assert html =~ "&quot;kind&quot;"
      assert html =~ "&quot;flavor&quot;"
      assert html =~ "CC Demo"
    end

    test "handles an empty option list" do
      assigns = %{options: []}

      html =
        rendered_to_string(~H"""
        <.uri_picker name="x" mode={:multi} options={@options} kinds={[:entity]} />
        """)

      assert html =~ ~s(phx-hook="UriPicker")
      assert html =~ "data-options="
    end
  end
end
