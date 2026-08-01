defmodule Ezagent.Cap.AuthorityReadErrorTest do
  use ExUnit.Case, async: true

  alias Ezagent.Cap.AuthorityReadError

  # The fail-LOUD contract: `Ezagent.Identity.caps_match?/2`'s per-cap target
  # re-verify raises THIS (never a silent `false`) when the authority store is
  # transiently unreadable — the silent-denial class #1346 forbids. This covers
  # the exception's own contract; the raise wiring in `caps_match?/2` is the
  # `{:error, :authority_read_failed}` branch of `target_current?/1`.
  test "exception/1 builds a message naming the target + grantee" do
    target = Ezagent.URI.new!("entity://team-alpha/agent/svc")
    grantee = Ezagent.URI.new!("entity://team-alpha/user/alice")

    err = AuthorityReadError.exception(target: target, grantee: grantee)

    assert %AuthorityReadError{target: ^target, grantee: ^grantee} = err
    assert err.message =~ "authority-store read failed"
    assert err.message =~ URI.to_string(target)
    assert err.message =~ URI.to_string(grantee)
    assert err.message =~ "#1346"
  end

  test "exception/1 honors an explicit :message override" do
    err = AuthorityReadError.exception(message: "custom", target: nil, grantee: nil)
    assert err.message == "custom"
  end
end
