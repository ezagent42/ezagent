defmodule Ezagent.Invariants.CapIssuedBypassTrustKeysTest do
  @moduledoc """
  Ratchet for deletion of the former caller-forgeable `ctx.cap_issued` bypass.
  Per-Kind signing has no trusted boolean token: grant authorization and signing
  occur inside `K.grant`, and ordinary dispatch authorization consumes only a
  target-signed artifact.
  """

  use ExUnit.Case, async: true

  test "cap_issued is absent from all product code" do
    hits = grep_product("cap_issued")
    assert hits == [], "deleted cap_issued bypass reappeared:\n#{Enum.join(hits, "\n")}"
  end

  test "Runtime has no boolean grant bypass" do
    runtime = source("apps/ezagent_actor/lib/ezagent/kind/runtime.ex")

    # C5 §3.4 AuthzPort — the step-5.5 verifier call goes through the
    # config-resolved port (`authz().authorize_dispatch(`); the literal
    # `Ezagent.Cap.Verifier.authorize(` lives in the core adapter.
    assert runtime =~ "authz().authorize_dispatch("

    assert source("apps/ezagent_core/lib/ezagent/kind/adapters/authz_adapter.ex") =~
             "Ezagent.Cap.Verifier.authorize("

    refute runtime =~ "Map.get(ctx, :cap_issued"
    refute runtime =~ "ctx.cap_issued"
  end

  defp grep_product(pattern) do
    {output, status} =
      System.cmd(
        "grep",
        ["-rFn", pattern, Path.join(repo_root(), "apps"), "--include=*.ex"],
        stderr_to_stdout: false
      )

    if status > 1, do: raise("grep failed with exit #{status}")

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, repo_root() <> "/", ""))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  defp source(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
