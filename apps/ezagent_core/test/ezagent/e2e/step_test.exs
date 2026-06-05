defmodule Ezagent.E2E.StepTest do
  @moduledoc """
  #21 PR-2 — the scenario `step` macro captures the FULL contract (run + await + assert)
  as a compile-time content hash so the resolver (PR-3) invalidates a cached layer when
  ANY callback changes — not just `run` (codex r2). `layer_inputs` (helpers/prompts/
  fixtures) fold in at runtime so a helper change also invalidates (codex r1).
  """
  use ExUnit.Case, async: true

  # Define step fixtures in nested modules so each `step/2` macro call compiles in
  # isolation, exercising the compile-time hash.
  defmodule Base do
    import Ezagent.E2E.Step

    def s,
      do:
        step("seed",
          kind: :setup,
          run: fn ctx -> {:ok, Map.put(ctx, :x, 1)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> if ctx[:x] == 1, do: :ok, else: {:error, :nope} end
        )
  end

  defmodule SameBodies do
    import Ezagent.E2E.Step
    # byte-identical callbacks to Base.s → identical callback_hash
    def s,
      do:
        step("seed",
          kind: :setup,
          run: fn ctx -> {:ok, Map.put(ctx, :x, 1)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> if ctx[:x] == 1, do: :ok, else: {:error, :nope} end
        )
  end

  defmodule TightenedAwait do
    import Ezagent.E2E.Step
    # same run + assert, but a STRONGER await → callback_hash MUST differ (codex r2)
    def s,
      do:
        step("seed",
          kind: :setup,
          run: fn ctx -> {:ok, Map.put(ctx, :x, 1)} end,
          await: fn ctx -> if ctx[:settled], do: :ok, else: {:error, :pending} end,
          assert: fn ctx -> if ctx[:x] == 1, do: :ok, else: {:error, :nope} end
        )
  end

  test "step/2 builds a %Step{} with name, kind, callbacks, and a compile-time callback_hash" do
    s = Base.s()
    assert s.name == "seed"
    assert s.kind == :setup
    assert is_function(s.run, 1)
    assert is_function(s.await, 1)
    assert is_function(s.assert, 1)
    assert is_binary(s.callback_hash) and byte_size(s.callback_hash) == 64
    # callbacks actually work
    assert {:ok, ctx} = s.run.(%{})
    assert s.await.(ctx) == :ok
    assert s.assert.(ctx) == :ok
  end

  test "identical callback bodies → identical callback_hash" do
    assert Base.s().callback_hash == SameBodies.s().callback_hash
  end

  test "tightening ONLY the await callback → different callback_hash (full-contract hash)" do
    refute Base.s().callback_hash == TightenedAwait.s().callback_hash
  end

  test "inputs_hash folds the declared layer_inputs file contents into the key" do
    dir = Path.join(System.tmp_dir!(), "step-li-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    f = Path.join(dir, "prompt.txt")
    File.write!(f, "v1")
    on_exit(fn -> File.rm_rf(dir) end)

    s = %{Base.s() | layer_inputs: [f]}
    h1 = Ezagent.E2E.Step.inputs_hash(s)

    File.write!(f, "v2-changed")
    h2 = Ezagent.E2E.Step.inputs_hash(s)

    assert is_binary(h1) and byte_size(h1) == 64
    refute h1 == h2, "changing a layer_input file must change inputs_hash (codex r1)"
  end

  test "inputs_hash is stable when nothing changes" do
    assert Ezagent.E2E.Step.inputs_hash(Base.s()) == Ezagent.E2E.Step.inputs_hash(Base.s())
  end

  test "a non-inline (variable) callback FAILS TO COMPILE (enforced, not just documented)" do
    code = """
    defmodule BadStep#{System.unique_integer([:positive])} do
      import Ezagent.E2E.Step
      def s do
        f = fn _ -> :ok end
        step("x", run: f, await: fn _ -> :ok end, assert: fn _ -> :ok end)
      end
    end
    """

    assert_raise ArgumentError, ~r/inline `fn/, fn -> Code.compile_string(code) end
  end
end
