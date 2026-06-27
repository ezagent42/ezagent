defmodule Ezagent.ExternalMirror.AdapterBehaviourLegalityTest do
  use ExUnit.Case, async: true

  test "adapter behaviour keeps live-delivery contract abstract-only" do
    source =
      "../../../lib/ezagent/external_mirror/adapter.ex"
      |> Path.expand(__DIR__)
      |> File.read!()

    refute source =~ "Ezagent.Session"
    refute source =~ "Ezagent.Socialware"
  end
end
