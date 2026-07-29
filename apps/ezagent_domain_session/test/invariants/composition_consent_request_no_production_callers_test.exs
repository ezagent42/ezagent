defmodule Ezagent.Invariants.CompositionConsentRequestNoProductionCallersTest do
  @moduledoc """
  Codex round-3 pin: `Ezagent.Socialware.CompositionConsent.request/5` checks
  `requester == authenticated_principal`, but `authenticated_principal` is
  (today) an ordinary caller-supplied argument — nothing wires it from a real
  authentication boundary. That is SAFE only because there are currently ZERO
  production call sites (every existing caller is a test that constructs both
  arguments itself).

  This is a PIN, not a fix for the underlying gap: it fails the instant a
  production (non-test) call site appears, forcing whoever adds it to first
  read the `request/5` moduledoc contract and derive `authenticated_principal`
  from the dispatch/Kind runtime's authenticated context (`ctx.caller` /
  `ctx.authenticated_principal`) rather than a free argument — i.e. it forces
  reopening security review instead of letting the wiring land silently.
  Modeled on the same-BEAM producer enumeration in
  `apps/ezagent_core/test/invariants/cap_absorb_reachability_test.exs`.
  """
  use ExUnit.Case, async: true

  @request_call ~r/\bConsent\.request\(|CompositionConsent\.request\(/

  test "CompositionConsent.request/5 has no production (non-test) call sites yet" do
    root = repo_root()

    violations =
      root
      |> Path.join("apps/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.filter(fn file ->
        source = File.read!(file)
        source =~ @request_call
      end)

    assert violations == [],
           "request/5 gained a production call site outside of tests: " <>
             "#{inspect(violations)}. Before wiring it up, derive " <>
             "`authenticated_principal` from the dispatch context (ctx.caller / " <>
             "ctx.authenticated_principal), never a free function argument, and " <>
             "reopen security review per the moduledoc contract on request/5 " <>
             "(apps/ezagent_domain_session/lib/ezagent/socialware/composition_consent.ex)."
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
