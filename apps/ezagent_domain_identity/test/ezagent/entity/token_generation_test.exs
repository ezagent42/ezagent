defmodule Ezagent.Entity.TokenGenerationTest do
  @moduledoc """
  Unified-revocation G-2: a PAT is bound to the principal authority generation
  at mint time. A standalone generation bump invalidates the existing PAT and
  ordinary minting cannot re-arm the revoked principal.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Entity.Token

  test "a PAT minted at generation N is rejected after the principal bumps" do
    principal = unique_agent("stale-pat")
    assert {:ok, first} = Authority.open(principal, :agent)
    assert {plain, row} = Token.mint(principal, label: "g2")

    assert {:ok, ^principal} = Token.authenticate(plain)
    assert row.bound_generation == first.generation

    assert {:ok, bumped} = Authority.regenesis(principal, :agent)
    assert bumped.generation == first.generation + 1

    assert {:error, :invalid_credentials} = Token.authenticate(plain)
    assert {:error, :principal_revoked} = Token.mint(principal, label: "must-not-rearm")
  end

  test "a legacy/null-generation PAT fails closed" do
    principal = unique_agent("null-generation")
    assert {:ok, _authority} = Authority.open(principal, :agent)
    assert {plain, row} = Token.mint(principal)

    row
    |> Ecto.Changeset.change(%{bound_generation: nil})
    |> EzagentCore.Repo.update!()

    assert {:error, :invalid_credentials} = Token.authenticate(plain)
  end

  defp unique_agent(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/token-generation-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
