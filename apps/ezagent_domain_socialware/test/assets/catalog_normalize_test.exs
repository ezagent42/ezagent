defmodule EzagentDomainSocialware.Assets.CatalogNormalizeTest do
  @moduledoc """
  Runs the @json-render/shadcn customer-renderer normalization contract
  (`assets/test/catalog_normalize_test.mjs`) under Node. This guards the two
  renderer regressions the migration to `@json-render/shadcn` introduced:
  Table `rows` coercion (the `row.map is not a function` crash) and the vertical
  Stack `align:stretch` default (the squished grid/cards bug). Pure Node — no
  bundler/jsdom — so it asserts the exact `normalizeSpec` the live page runs.
  """
  use ExUnit.Case, async: true

  @renderer_test Path.expand("../../assets/test/catalog_normalize_test.mjs", __DIR__)

  test "catalog normalize contract" do
    {output, status} = System.cmd("node", [@renderer_test], stderr_to_stdout: true)
    assert status == 0, output
  end
end
