defmodule Ezagent.PluginCurlAgent.LifecycleCaseImportTest do
  @moduledoc """
  T2 proof — a PLUGIN app (curl_agent) can `use Ezagent.LifecycleCase` and
  see its imported helpers (`assert_transients_rebuilt/2`, `wait_until/1-2`).

  Before T2 the case template lived in `ezagent_core/test/support/`, which
  is only on `ezagent_core`'s own elixirc path — so this `use` would fail
  to compile in any other app. Relocated to `ezagent_core/lib/`, it is now
  on every dependent app's compile path (same as `EzagentCore.DataCase`),
  which is exactly what the Phase B plugin / domain conversion batches need
  to assert the cold-restart invariant on their converted modules.
  """

  use Ezagent.LifecycleCase, async: false

  test "the cross-app import resolves: assert_transients_rebuilt/2 + wait_until are available" do
    # `import Ezagent.LifecycleCase` (via the case template) brings these
    # into scope; `function_exported?` proves the module compiled into a
    # place this plugin app can reach.
    assert function_exported?(Ezagent.LifecycleCase, :assert_transients_rebuilt, 2)
    assert function_exported?(Ezagent.LifecycleCase, :wait_until, 1)

    # And the imported helper is callable here (it is in scope from the
    # `use`), proving the import — not merely the module load — works.
    assert wait_until(fn -> true end) == :ok
  end
end
