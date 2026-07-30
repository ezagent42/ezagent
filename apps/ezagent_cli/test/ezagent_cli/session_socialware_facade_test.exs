defmodule EzagentCli.SessionSocialwareFacadeTest do
  use ExUnit.Case, async: true

  alias EzagentCli.{FacadeRegistry, SessionSocialwareFacade}

  test "registers the runtime socialware reinstall operation on sessions" do
    :ok = SessionSocialwareFacade.register_all()

    assert {:ok, _fun, spec} = FacadeRegistry.lookup(:session, :reinstall_socialware)
    assert spec.opts == [session: :uri]
  end
end
