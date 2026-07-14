Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.CapSigningFailLoudTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "Phase-4 verify callers never rescue an infrastructure failure to false" do
    assert_zero(:cap_verify_rescue_to_false)
  end

  test "scanner recognizes rescue-to-false inside a verification function" do
    source = """
    def verify(cap) do
      try do
        verify_signature(cap)
      rescue
        _error -> false
      end
    end
    """

    assert Scan.count_cap_verify_rescue_to_false_in_source(source) == 1
  end

  test "scanner recognizes an if branch in rescue that denies verification" do
    source = """
    def verify(cap) do
      try do
        verify_signature(cap)
      rescue
        _error -> if retryable?(cap), do: false, else: raise("signing unavailable")
      end
    end
    """

    assert Scan.count_cap_verify_rescue_to_false_in_source(source) == 1
  end

  test "scanner recognizes a case branch in rescue that denies verification" do
    source = """
    def verify(cap) do
      try do
        verify_signature(cap)
      rescue
        _error ->
          case retryable?(cap) do
            true -> raise "signing unavailable"
            false -> false
          end
      end
    end
    """

    assert Scan.count_cap_verify_rescue_to_false_in_source(source) == 1
  end

  test "scanner does not confuse a genuine deny with a rescued infrastructure failure" do
    source = """
    def verify(cap) do
      with true <- valid?(cap) do
        true
      else
        _ -> false
      end
    end
    """

    assert Scan.count_cap_verify_rescue_to_false_in_source(source) == 0
  end

  test "scanner ignores rescue-to-false outside the verification call chain" do
    source = """
    def parse_event(payload) do
      try do
        decode(payload)
      rescue
        _error -> false
      end
    end
    """

    assert Scan.count_cap_verify_rescue_to_false_in_source(source) == 0
  end
end
