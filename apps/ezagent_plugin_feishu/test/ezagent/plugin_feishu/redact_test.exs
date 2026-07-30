defmodule EzagentPluginFeishu.RedactTest do
  @moduledoc """
  Handoff B1 — Locked Decision #12: shared logs/errors must never carry a
  full open_id or user URI. `fingerprint/1` is the shared short,
  non-reversible correlation token used by the seed importer and the
  Behavior's rollback logging.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginFeishu.Redact

  test "fingerprint is deterministic for the same input" do
    a = Redact.fingerprint("ou_secret_123")
    b = Redact.fingerprint("ou_secret_123")
    assert a == b
  end

  test "fingerprint is short (correlation token, not a full digest)" do
    assert String.length(Redact.fingerprint("ou_secret_123")) == 8
  end

  test "different inputs produce different fingerprints" do
    refute Redact.fingerprint("ou_a") == Redact.fingerprint("ou_b")
  end

  test "fingerprint never contains the original value" do
    value = "ou_1234567890abcdef_super_secret"
    refute Redact.fingerprint(value) =~ value
  end

  test "fingerprint of a full user URI never leaks the URI" do
    uri = "entity://team-alpha/user/alice"
    fp = Redact.fingerprint(uri)
    refute fp =~ "team-alpha"
    refute fp =~ "alice"
    refute fp =~ uri
  end
end
