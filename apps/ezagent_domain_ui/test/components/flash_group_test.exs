defmodule EzagentDomainUi.Components.FlashGroupTest do
  @moduledoc """
  PR-B (Allen 2026-05-23) — shared `<.flash_group>` primitive.

  Pins the component contract so LVs migrating from inline flash
  rendering have a stable target.
  """

  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component

  defp render_with(flash, opts \\ []) do
    class = Keyword.get(opts, :class, "")
    assigns = %{flash: flash, class: class}

    rendered_to_string(~H"""
    <EzagentDomainUi.Components.flash_group flash={@flash} class={@class} />
    """)
  end

  describe "flash_group/1" do
    test "renders nothing when flash is empty" do
      html = render_with(%{})
      refute html =~ "role=\"status\""
      refute html =~ "role=\"alert\""
    end

    test "renders :info bubble when flash[:info] present" do
      html = render_with(%{"info" => "Saved successfully"})
      assert html =~ "Saved successfully"
      # a11y: info gets role=status
      assert html =~ ~s(role="status")
    end

    test "renders :error bubble when flash[:error] present" do
      html = render_with(%{"error" => "Validation failed"})
      assert html =~ "Validation failed"
      # a11y: error gets role=alert
      assert html =~ ~s(role="alert")
    end

    test "renders BOTH when both present (info first, then error)" do
      html = render_with(%{"info" => "info-text", "error" => "error-text"})

      info_pos = :binary.match(html, "info-text") |> elem(0)
      error_pos = :binary.match(html, "error-text") |> elem(0)
      assert info_pos < error_pos
    end

    test "extra class is appended after defaults" do
      html = render_with(%{"info" => "x"}, class: "my-custom-class")
      assert html =~ "my-custom-class"
    end
  end
end
