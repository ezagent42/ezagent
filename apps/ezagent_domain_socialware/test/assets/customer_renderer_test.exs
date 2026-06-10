defmodule EzagentDomainSocialware.Assets.CustomerRendererTest do
  use ExUnit.Case, async: true

  @renderer_test Path.expand("../../assets/test/customer_renderer_test.mjs", __DIR__)

  test "customer renderer contract" do
    {output, status} = System.cmd("node", [@renderer_test], stderr_to_stdout: true)
    assert status == 0, output
  end
end
