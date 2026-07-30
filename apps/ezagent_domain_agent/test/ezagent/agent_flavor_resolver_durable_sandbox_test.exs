defmodule Ezagent.AgentFlavorResolverDurableSandboxTest do
  @moduledoc """
  Regression for the "@mention py agent → no reply" bug (found in #1128 retest).

  A py agent is `:in_process_sync`: its chat reply only lands when
  `Ezagent.ActionSet.Agent.Delivery.deliver_agent_receive/2` resolves its
  flavor to `{:ok, "py"}` and takes the sync branch (which re-dispatches into
  the `:py_sync_result` Behavior that persists the reply). If the flavor
  resolves to `:none`, delivery falls through to the `:subprocess_ws` async
  branch and the reply is silently DROPPED.

  On a COLD-loaded agent (ETS `AgentFlavorAttributes` gone after a BEAM
  restart / lazy demand-spawn) delivery falls back to
  `AgentFlavorResolver.flavor_from_durable_snapshot/1`. That fallback scanned
  ONLY for a persisted `:flavor` field — which curl has (its `:curl_agent`
  slice) but **py does not**: py persists its identity as a `template_class`
  in the `:sandbox` slice. So a cold-loaded py agent resolved `:none` →
  mis-routed → no reply.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CredentialConnection
  alias Ezagent.AgentFlavorResolver

  defmodule PyLikeTemplate do
    @behaviour Ezagent.Kind.Template
    @impl true
    def template_name, do: "test.py_like_durable_agent"
    @impl true
    def config_dir_namespace, do: "cc"
    @impl true
    def validate(_data), do: :ok
    @impl true
    def instantiate(_name, _data, _workspace_uri), do: {:error, :not_used_in_this_test}
  end

  test "durable snapshot recovers flavor from a :sandbox template_class (py-style, no :flavor field)" do
    unique = System.unique_integer([:positive])
    flavor = "py-like-#{unique}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: PyLikeTemplate
      })

    uri = Ezagent.URI.new!("entity://pylike-#{unique}/agent/cold")

    # A py-style durable snapshot: the `:sandbox` slice carries `template_class`
    # (how py persists its flavor), and NO slice carries a `:flavor` field.
    state = %{
      sandbox: %{template_class: PyLikeTemplate, config_dir_path: "/tmp/pylike-#{unique}"}
    }

    {:ok, _} = Ezagent.SnapshotStore.write(uri, state, kind_type: :agent)

    # Must recover the flavor from the sandbox template_class — else a
    # cold-loaded py agent mis-routes its :in_process_sync reply and drops it.
    assert {:ok, ^flavor} = AgentFlavorResolver.flavor_from_durable_snapshot(uri)
  end

  test "curl-style durable snapshot (a :flavor field) still resolves" do
    unique = System.unique_integer([:positive])
    uri = Ezagent.URI.new!("entity://curllike-#{unique}/agent/cold")
    state = %{curl_agent: %{flavor: "curl", some: "state"}}
    {:ok, _} = Ezagent.SnapshotStore.write(uri, state, kind_type: :agent)

    assert {:ok, "curl"} = AgentFlavorResolver.flavor_from_durable_snapshot(uri)
  end

  test "registered interactive and API-key flavors declare their connection surfaces" do
    assert {:ok, {:pty, %{label: "Connect Codex"}}} =
             CredentialConnection.for_flavor("codex")

    assert {:ok, {:pty, %{label: "Connect Codex"}}} =
             CredentialConnection.for_flavor("codex-remote")

    assert {:ok, {:pty, %{label: "Connect Claude"}}} =
             CredentialConnection.for_flavor("cc")

    assert {:ok, {:pty, %{label: "Connect Claude"}}} =
             CredentialConnection.for_flavor("cc-headless")

    assert {:ok, {:api_key, %{provider: "deepseek", label: "Configure API key"}}} =
             CredentialConnection.for_flavor("curl",
               role: %{role_name: "llm", provider: "deepseek"}
             )

    assert {:error, :unsupported_connection} =
             CredentialConnection.for_flavor("curl", role: %{role_name: "llm"})
  end
end
