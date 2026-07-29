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
  read the contract on `request/5` and derive `authenticated_principal` from
  the dispatch/Kind runtime's authenticated context (`ctx.caller` /
  `ctx.authenticated_principal`) rather than a free argument — i.e. it forces
  reopening security review instead of letting the wiring land silently.

  Codex round-4: the pin enumerates callers from COMPILED BEAM code via
  `:xref` (every remote-call edge in the umbrella's `_build` ebins), not from
  a source-text regex — so aliasing (`alias ... as: C`), `import`, or any
  macro-generated call cannot slip past it. Test-support modules (compiled
  into ebin under `MIX_ENV=test`) are excluded by their `module_info(:compile)`
  source path. Dynamic `apply/3` with runtime-built atoms is invisible to any
  static analysis; the accidental-caller channel this pins is the static one.
  A POSITIVE CONTROL asserts the xref graph does see other production callers
  of this module, so an empty result can never be a silently-broken harness.
  """
  use ExUnit.Case, async: true

  @callee_module :"Elixir.Ezagent.Socialware.CompositionConsent"

  test "CompositionConsent.request/5 has no production (non-test) call sites yet (BEAM xref)" do
    # `:xref` lives in OTP's `:tools` app, which Elixir's code-path pruning
    # hides from `mix test` unless explicitly ensured.
    Mix.ensure_application!(:tools)
    {:ok, xref} = :xref.start([])

    try do
      :xref.set_default(xref, warnings: false)

      ebins =
        [Mix.Project.build_path(), "lib", "*", "ebin"]
        |> Path.join()
        |> Path.wildcard()

      assert ebins != [], "no compiled ebins under #{Mix.Project.build_path()} — harness broken"
      for ebin <- ebins, do: :xref.add_directory(xref, String.to_charlist(ebin))

      # POSITIVE CONTROL — the harness must SEE production callers of this
      # module (session.ex / composition_caps.ex call its read/decide side).
      # If this is empty the xref graph is broken and the pin below would be
      # vacuously green.
      module_callers = production_caller_mfas(xref, @callee_module)

      assert module_callers != [],
             "xref positive control failed: no production caller edges into " <>
               "#{inspect(@callee_module)} at all — the caller enumeration is broken, " <>
               "so the request/5 pin below cannot be trusted"

      # Match ANY arity of `:request` — not just /5. Xref records a static
      # `apply(CompositionConsent, :request, args)` with a VARIABLE arg list
      # as arity -1 (codex round-5), and an exact-/5 filter would drop that
      # edge. `request` exists only as /5, so any-arity is exactly the pin.
      request_callers =
        module_callers
        |> Enum.filter(fn {_caller, {mod, fun, _arity}} ->
          mod == @callee_module and fun == :request
        end)

      assert request_callers == [],
             "request/5 gained a production call site outside of tests: " <>
               "#{inspect(request_callers)}. Before wiring it up, derive " <>
               "`authenticated_principal` from the dispatch context (ctx.caller / " <>
               "ctx.authenticated_principal), never a free function argument, and " <>
               "reopen security review per the contract on request/5 " <>
               "(apps/ezagent_domain_session/lib/ezagent/socialware/composition_consent.ex)."
    after
      :xref.stop(xref)
    end
  end

  # Every remote-call edge into `callee_module` whose CALLER is production
  # code: not the module itself, and not compiled from a test/ source file
  # (test-support modules land in ebin under MIX_ENV=test).
  defp production_caller_mfas(xref, callee_module) do
    query = ~c"E || '#{callee_module}'"
    {:ok, edges} = :xref.q(xref, query)

    edges
    |> Enum.filter(fn {{caller_mod, _f, _a}, _callee} ->
      caller_mod != callee_module and not test_module?(caller_mod)
    end)
  end

  defp test_module?(mod) do
    source =
      try do
        mod.module_info(:compile)[:source] |> to_string()
      rescue
        _ -> ""
      end

    String.contains?(source, "/test/") or String.ends_with?(source, "_test.exs")
  end
end
