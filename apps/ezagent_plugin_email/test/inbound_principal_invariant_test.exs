defmodule Ezagent.Email.Inbound.PrincipalInvariantTest do
  use ExUnit.Case, async: true

  @email_lib Path.expand("../lib/ezagent/email", __DIR__)
  @authority Path.join(@email_lib, "inbound/authority.ex")

  test "email has one authority issuance home and no arbitrary principal mint API" do
    sources =
      @email_lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Map.new(&{&1, File.read!(&1)})

    issue_homes = for {path, source} <- sources, source =~ "Ezagent.Cap.issue", do: path

    assert issue_homes == [@authority]
    refute function_exported?(Ezagent.Email.Inbound.Principal, :mint, 2)
  end
end
