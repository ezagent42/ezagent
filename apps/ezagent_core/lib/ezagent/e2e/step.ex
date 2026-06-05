defmodule Ezagent.E2E.Step do
  @moduledoc """
  #21 PR-2 — one named step of an E2E scenario.

  A step has up to three callbacks, run by the `Runner` in this order:

    * `run(ctx) :: {:ok, ctx} | {:error, reason}` — perform the action (domain setup via
      `Ezagent.Invocation.dispatch`, or an ingress event via `InboundDispatcher`).
    * `await(ctx) :: :ok | {:error, pending}` — QUIESCENCE barrier: positively observe all
      expected DURABLE outcomes before a snapshot is taken (relay/model work is async).
    * `assert(ctx) :: :ok | {:error, detail}` — correctness check; a layer is published only
      AFTER this passes (codex r2).

  ## The hash (codex r1 + r2)

  `step/2` is a macro that captures the **run + await + assert** ASTs at compile time into
  `callback_hash` — so tightening ANY callback (not just `run`) invalidates a cached layer.
  `inputs_hash/1` folds in the runtime contents of the declared `layer_inputs`
  (helper/prompt/fixture paths) so a helper change also invalidates. The chain hash the
  resolver (PR-3) keys on is built from `inputs_hash/1`.
  """

  defstruct [
    :name,
    :run,
    :await,
    :assert,
    :callback_hash,
    kind: :setup,
    layer_inputs: [],
    cacheable: true
  ]

  @type ctx :: map()
  @type t :: %__MODULE__{
          name: String.t(),
          kind: :setup | :ingress,
          run: (ctx -> {:ok, ctx} | {:error, term()}),
          await: (ctx -> :ok | {:error, term()}),
          assert: (ctx -> :ok | {:error, term()}),
          callback_hash: String.t(),
          layer_inputs: [String.t()],
          cacheable: boolean()
        }

  @doc """
  Define a scenario step. `opts`: `:run` (required), `:await`, `:assert`, `:kind`
  (`:setup` | `:ingress`), `:layer_inputs` (paths), `:cacheable`.

  IMPORTANT: the `:run`/`:await`/`:assert` callbacks MUST be **inline literals** at the
  `step` call site — the macro hashes their AST *here*, so a fn passed via a variable
  would hash to the variable name (identical for every step). Factor shared logic into a
  helper module, declare it in `:layer_inputs`, and call it inline
  (`run: fn ctx -> MyHelpers.seed(ctx) end`) so helper changes still invalidate.

      step "seed admin",
        run: fn ctx -> {:ok, Map.put(ctx, :admin, uri)} end,
        await: fn _ctx -> :ok end,
        assert: fn ctx -> if ctx[:admin], do: :ok, else: {:error, :no_admin} end
  """
  defmacro step(name, opts) do
    run_ast = assert_inline_fn!(Keyword.fetch!(opts, :run), :run)

    await_ast =
      assert_inline_fn!(Keyword.get(opts, :await, quote(do: fn _ctx -> :ok end)), :await)

    assert_ast =
      assert_inline_fn!(Keyword.get(opts, :assert, quote(do: fn _ctx -> :ok end)), :assert)

    layer_inputs = Keyword.get(opts, :layer_inputs, [])
    kind = Keyword.get(opts, :kind, :setup)
    cacheable = Keyword.get(opts, :cacheable, true)

    src =
      Macro.to_string(run_ast) <>
        <<0>> <> Macro.to_string(await_ast) <> <<0>> <> Macro.to_string(assert_ast)

    callback_hash = :crypto.hash(:sha256, src) |> Base.encode16(case: :lower)

    quote do
      %unquote(__MODULE__){
        name: unquote(name),
        kind: unquote(kind),
        run: unquote(run_ast),
        await: unquote(await_ast),
        assert: unquote(assert_ast),
        layer_inputs: unquote(layer_inputs),
        cacheable: unquote(cacheable),
        callback_hash: unquote(callback_hash)
      }
    end
  end

  # ENFORCE the inline-literal contract (codex review): a variable/captured callback would
  # hash to its name, not its body, silently breaking invalidation. Require `fn ... end`.
  defp assert_inline_fn!({:fn, _, _} = ast, _which), do: ast

  defp assert_inline_fn!(ast, which) do
    raise ArgumentError,
          "Ezagent.E2E.Step.step/2: `:#{which}` must be an inline `fn ... end` literal " <>
            "(got `#{Macro.to_string(ast)}`). A variable/captured callback would hash to its " <>
            "name, not its body, defeating cache invalidation. Factor shared logic into a " <>
            "helper module, declare it in `:layer_inputs`, and call it inline: " <>
            "`#{which}: fn ctx -> MyHelpers.do_it(ctx) end`."
  end

  @doc """
  Full per-step input hash = `callback_hash` (run+await+assert ASTs) combined with the
  current contents of every declared `layer_inputs` file. A missing input contributes a
  stable marker so its later appearance still changes the hash.
  """
  @spec inputs_hash(t()) :: String.t()
  def inputs_hash(%__MODULE__{callback_hash: cb, layer_inputs: inputs}) do
    li =
      inputs
      |> Enum.sort()
      |> Enum.map(&hash_input/1)
      |> Enum.join(<<0>>)

    :crypto.hash(:sha256, [to_string(cb), <<0>>, li]) |> Base.encode16(case: :lower)
  end

  defp hash_input(path) do
    case File.read(path) do
      {:ok, bin} -> :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
      {:error, _} -> "missing:" <> path
    end
  end
end
