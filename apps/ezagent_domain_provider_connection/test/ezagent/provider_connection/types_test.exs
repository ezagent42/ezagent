defmodule Ezagent.ProviderConnection.TypesTest do
  use ExUnit.Case, async: true

  alias Ezagent.ProviderConnection.Types

  test "publishes the frozen identifiers and closed value unions as real typespecs" do
    {:ok, types} = Code.Typespec.fetch_types(Types)
    names = for {_kind, {name, _type, _args}} <- types, do: name

    assert Enum.sort(names) ==
             Enum.sort([
               :attempt_ref,
               :authorization_ref,
               :connection_id,
               :provider_id,
               :operation_class,
               :status,
               :attempt_status,
               :operation_status,
               :consume_status,
               :error
             ])
  end
end
