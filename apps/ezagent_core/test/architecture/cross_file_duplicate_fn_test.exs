Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.CrossFileDuplicateFnTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  # FF-1: groups of ≥2 lib files sharing a byte-identical (whitespace-normalized,
  # ≥120-char) function body — the broad "fork accretion" fitness function that
  # generalizes `duplicated_resolve_template_class`. OTP/behaviour-callback names
  # are allowlisted in the scanner so the count reflects real copy-paste forks.
  test "cross-file duplicate function-body groups do not grow beyond baseline" do
    assert_at_or_below(:cross_file_duplicate_fn_groups)
  end
end
