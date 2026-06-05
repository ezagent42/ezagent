defmodule Ezagent.E2E.Scenario do
  @moduledoc """
  #21 PR-2 — an ordered list of `Ezagent.E2E.Step`s, optionally built on a `base`
  scenario's final layer (scenario 0's base is blank).

  `fp_chain/2` is the docker-layer-style chain hash the resolver (PR-3) keys on:
  `fp(-1) = H(base_fp <> env_image_id)`, `fp(N) = H(fp(N-1) <> inputs_hash(step_N))`.
  A change to step K's contract or declared inputs changes `fp(K..)`, so cached layers
  at/after K stop matching — automatic invalidation, no manual versioning.
  """

  alias Ezagent.E2E.Step

  defstruct [:id, :base, steps: []]

  @type t :: %__MODULE__{id: String.t(), base: String.t() | nil, steps: [Step.t()]}

  @doc """
  The cumulative fingerprint chain — one entry per step (`fp(0)..fp(N-1)`), where each
  entry is valid only if all prior steps + `env_image_id` are unchanged.
  """
  @spec fp_chain(t(), String.t()) :: [String.t()]
  def fp_chain(%__MODULE__{base: base, steps: steps}, env_image_id) do
    base_fp = enc(:crypto.hash(:sha256, [to_string(base || ""), <<0>>, to_string(env_image_id)]))

    {chain, _last} =
      Enum.map_reduce(steps, base_fp, fn step, prev ->
        fp = enc(:crypto.hash(:sha256, [prev, <<0>>, Step.inputs_hash(step)]))
        {fp, fp}
      end)

    chain
  end

  defp enc(bin), do: Base.encode16(bin, case: :lower)
end
