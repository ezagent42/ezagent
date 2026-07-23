defmodule Ezagent.Agent.LaunchAuthorityTest do
  use ExUnit.Case, async: false

  alias Ezagent.Agent.LaunchAuthority

  defmodule ValidAuthority do
    @behaviour LaunchAuthority

    @impl true
    def resolve_launch(handle, uri), do: {:ok, {handle, uri}}

    @impl true
    def acknowledge_launch(issuer_ref), do: {:ok, issuer_ref}
  end

  defmodule OtherAuthority do
    @behaviour LaunchAuthority

    @impl true
    def resolve_launch(_handle, _uri), do: {:error, :unused}

    @impl true
    def acknowledge_launch(_issuer_ref), do: :ok
  end

  defmodule MissingCallback do
    def resolve_launch(_handle, _uri), do: {:error, :unused}
  end

  setup do
    :ok = Supervisor.terminate_child(EzagentDomainAgent.Supervisor, LaunchAuthority)
    {:ok, _pid} = Supervisor.restart_child(EzagentDomainAgent.Supervisor, LaunchAuthority)

    on_exit(fn ->
      :ok = Supervisor.terminate_child(EzagentDomainAgent.Supervisor, LaunchAuthority)
      {:ok, _pid} = Supervisor.restart_child(EzagentDomainAgent.Supervisor, LaunchAuthority)
    end)

    :ok
  end

  test "registration is single-writer, idempotent, and validates implementations" do
    assert :ok = LaunchAuthority.register(ValidAuthority)
    assert :ok = LaunchAuthority.register(ValidAuthority)

    assert {:error, {:already_registered, ValidAuthority}} =
             LaunchAuthority.register(OtherAuthority)

    assert {:error, :invalid_launch_authority} = LaunchAuthority.register(MissingCallback)
    assert {:error, :invalid_launch_authority} = LaunchAuthority.register(:module_does_not_exist)
    assert {:error, :invalid_launch_authority} = LaunchAuthority.register("not-a-module")
  end

  test "the facade rejects malformed calls before invoking the implementation" do
    assert {:error, :invalid_launch_context} =
             LaunchAuthority.resolve(:not_a_reference, URI.parse("https://example.com"))

    assert {:error, :invalid_agent_uri} = LaunchAuthority.resolve(make_ref(), :not_a_uri)
    assert {:error, :invalid_launch_issuer_ref} = LaunchAuthority.acknowledge(:not_an_issuer_ref)
  end

  test "resolution and acknowledgement fail closed without an implementation" do
    handle = make_ref()
    agent_uri = Ezagent.URI.agent("launch-authority-port", "worker")

    assert {:error, :launch_authority_not_registered} =
             LaunchAuthority.resolve(handle, agent_uri)

    assert {:error, :launch_authority_not_registered} =
             LaunchAuthority.acknowledge({handle, "claim"})
  end
end
