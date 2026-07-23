defmodule Ezagent.Cap.RuntimeViewTest do
  @moduledoc """
  Save/restore hygiene for the in-process runtime-view compartment.

  A leaked entry would let a LATER self-target resolution read a STALE instance's
  `slice_state` — a correctness AND security hazard — so `with_current/3` MUST
  restore the outer value (or clear it) on every exit path, including nesting and
  exceptions.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Cap.RuntimeView

  defmodule KindA, do: def(type_name, do: :agent)
  defmodule KindB, do: def(type_name, do: :session)

  @slice_a %{kind_base: %{behaviors: [KindA]}}
  @slice_b %{kind_base: %{behaviors: [KindB]}}

  test "current/0 is :error with no view installed" do
    assert RuntimeView.current() == :error
  end

  test "with_current/3 installs the view for the duration of the fun and clears it after" do
    assert :done ==
             RuntimeView.with_current(KindA, @slice_a, fn ->
               assert RuntimeView.current() == {:ok, {KindA, @slice_a}}
               :done
             end)

    # Cleared on exit — no leak into a later resolution.
    assert RuntimeView.current() == :error
  end

  test "nested with_current/3 restores the OUTER view on inner exit (no stale leak)" do
    RuntimeView.with_current(KindA, @slice_a, fn ->
      assert RuntimeView.current() == {:ok, {KindA, @slice_a}}

      RuntimeView.with_current(KindB, @slice_b, fn ->
        # Inner scope shadows the outer.
        assert RuntimeView.current() == {:ok, {KindB, @slice_b}}
      end)

      # Outer restored exactly — NOT the inner instance's slice_state.
      assert RuntimeView.current() == {:ok, {KindA, @slice_a}}
    end)

    assert RuntimeView.current() == :error
  end

  test "with_current/3 restores the previous view even when the fun raises (try/after)" do
    RuntimeView.with_current(KindA, @slice_a, fn ->
      assert_raise RuntimeError, fn ->
        RuntimeView.with_current(KindB, @slice_b, fn -> raise "boom" end)
      end

      # The raising inner scope must NOT leave KindB installed.
      assert RuntimeView.current() == {:ok, {KindA, @slice_a}}
    end)

    assert RuntimeView.current() == :error
  end
end
