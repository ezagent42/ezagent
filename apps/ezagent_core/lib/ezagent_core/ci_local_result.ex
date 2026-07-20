defmodule EzagentCore.CiLocalResult do
  @moduledoc """
  Honest exit-code capture for `mix ci.local`.

  `mix test` signals failures via an ExUnit `System.at_exit` hook (it does NOT
  raise). `mix.exs`'s `finalize_ci_local/1` ends `ci.local` with an explicit
  `System.halt/1` — which exists to DODGE the erlexec port-EXIT graceful-shutdown
  race that pollutes a CLEAN run's exit code to 2 — but `halt` bypasses
  `at_exit`, so failures were silently swallowed (false green).

  This module captures the ExUnit result via an `after_suite` callback
  (synchronous, runs before any exit/shutdown, immune to the `halt` bypass) into
  a sentinel file named by the `EZAGENT_CI_LOCAL_SENTINEL` env var (set by
  `arm_ci_local_result_capture/1` in mix.exs). `finalize_ci_local/1` then
  `halt(1)` iff `failed?/0`, else `halt(0)` — honest failures WITHOUT
  reintroducing the shutdown-timeout false-red.

  A no-op outside a `ci.local` run (env var unset), so registering it globally is
  harmless to a plain `mix test` or the CI `gate`.
  """

  @env "EZAGENT_CI_LOCAL_SENTINEL"

  @doc "ExUnit `after_suite` callback. Sticky-marks the sentinel when the suite reports failures."
  @spec record_result(map()) :: :ok
  def record_result(result) when is_map(result) do
    # ExUnit folds `invalid` (setup_all crashes) into `:failures`; OR `:invalid`
    # defensively in case a future ExUnit exposes it separately.
    failures = Map.get(result, :failures, 0) + Map.get(result, :invalid, 0)

    with path when is_binary(path) <- System.get_env(@env),
         true <- failures > 0 do
      File.write!(path, "FAIL failures=#{failures}\n", [:append])
    end

    :ok
  end

  def record_result(_), do: :ok

  @doc "True iff any suite in this ci.local run reported a failure."
  @spec failed?() :: boolean()
  def failed? do
    case System.get_env(@env) do
      path when is_binary(path) -> File.exists?(path)
      _ -> false
    end
  end
end
