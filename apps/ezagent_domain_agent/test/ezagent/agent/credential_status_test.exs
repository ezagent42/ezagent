defmodule Ezagent.Agent.CredentialStatusTest do
  @moduledoc """
  #160 — the flavor-agnostic credential-status router. Exercised through FAKE
  Template Classes (a file-credentialled one, a slice-credentialled one, and a
  credential-less one) so the router's routing logic is tested WITHOUT coupling to
  the cc/codex/curl plugins — the plugin-isolation seam. Slice presence is read
  from a durable snapshot; the router NEVER activates the agent.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CredentialStatus
  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.SnapshotStore

  defmodule FakeKind do
  end

  # A file-credentialled fake flavor: full declarative CredentialAdapter group +
  # the optional credential_status/2 (returns a status driven by `opts[:fake]`, so
  # the router's opts-forwarding + field pass-through is observable).
  defmodule FileTC do
    @behaviour Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "FAKE_HOME"
    def credential_relpaths, do: ["cred"]
    def secret_relpaths, do: ["cred"]
    def auth_failure_signals, do: []

    def credential_status(config_dir, opts) do
      %{
        status: Keyword.get(opts, :fake, :authenticated),
        detail: "d-#{config_dir}",
        expires_at: 999
      }
    end
  end

  # A slice-credentialled fake flavor (like curl) — creds in the :api_keys slice.
  defmodule SliceTC do
    @behaviour Ezagent.Agent.CredentialSliceAdapter
    def credential_slice, do: :api_keys
    def materialize_credential_slice(_uri, _data), do: :ok
  end

  # Credential-less (like py/echo/np) — implements NEITHER adapter.
  defmodule NoCredsTC do
  end

  defp register(template_class) do
    flavor = "credstat-#{System.unique_integer([:positive])}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: FakeKind,
        template_class: template_class
      })

    flavor
  end

  defp agent_uri,
    do: Ezagent.URI.entity(:team_alpha, :agent, "cs-#{System.unique_integer([:positive])}")

  defp cold?(uri), do: Ezagent.KindRegistry.lookup(URI.to_string(uri)) == :error

  test "statuses/0 is the complete normalized enum" do
    assert CredentialStatus.statuses() ==
             [:authenticated, :expiring, :expired, :missing, :n_a, :unknown]
  end

  describe "file-credentialled flavor" do
    test "routes to the TC probe and merges flavor + checked_at; forwards opts" do
      flavor = register(FileTC)
      uri = agent_uri()

      res = CredentialStatus.classify(uri, flavor, "/some/dir", fake: :expired)

      assert res.status == :expired
      assert res.detail == "d-/some/dir"
      assert res.expires_at == 999
      assert res.flavor == flavor
      assert %DateTime{} = res.checked_at
    end

    test "defaults to the TC's status when no opts" do
      flavor = register(FileTC)
      assert %{status: :authenticated} = CredentialStatus.classify(agent_uri(), flavor, "/d")
    end
  end

  describe "slice-credentialled flavor (curl-like)" do
    test "non-empty keys in the durable snapshot → :authenticated, without activating" do
      flavor = register(SliceTC)
      uri = agent_uri()

      {:ok, _} =
        SnapshotStore.write(
          uri,
          %{api_keys: %{keys: %{"openai" => "sk-x"}, creator_uri: nil}},
          kind_type: :agent
        )

      assert cold?(uri)

      assert %{status: :authenticated, flavor: ^flavor} =
               CredentialStatus.classify(uri, flavor, nil)

      assert cold?(uri), "classify must not activate the agent"
    end

    test "empty keys slice → :missing" do
      flavor = register(SliceTC)
      uri = agent_uri()

      {:ok, _} =
        SnapshotStore.write(uri, %{api_keys: %{keys: %{}, creator_uri: nil}}, kind_type: :agent)

      assert %{status: :missing} = CredentialStatus.classify(uri, flavor, nil)
    end

    test "cold agent with NO snapshot → :unknown (never an alarm)" do
      flavor = register(SliceTC)
      uri = agent_uri()
      assert cold?(uri)
      assert %{status: :unknown} = CredentialStatus.classify(uri, flavor, nil)
      assert cold?(uri)
    end
  end

  describe "credential-less flavor" do
    test "→ :n_a with no detail/expires_at" do
      flavor = register(NoCredsTC)

      assert %{status: :n_a, detail: nil, expires_at: nil} =
               CredentialStatus.classify(agent_uri(), flavor, nil)
    end
  end

  # §6.3 list plane — the agent directory pre-fetches every agent's credential
  # slice in ONE `read_durable_many/3` batch and threads it in, so N rows never
  # cost N per-agent snapshot reads.
  describe "directory batch (prefetched credential slice)" do
    test "classify uses a PRE-FETCHED slice — no per-agent read at all" do
      flavor = register(SliceTC)
      uri = agent_uri()
      # NO snapshot written: a per-agent read would yield :unknown. The status is
      # driven ENTIRELY by the prefetched slice (from the directory's batch).
      assert cold?(uri)

      assert %{status: :authenticated} =
               CredentialStatus.classify(uri, flavor, nil,
                 credential_slice: {:ok, %{keys: %{"openai" => "sk-x"}}}
               )

      assert %{status: :missing} =
               CredentialStatus.classify(uri, flavor, nil, credential_slice: {:ok, %{keys: %{}}})

      assert %{status: :unknown} =
               CredentialStatus.classify(uri, flavor, nil, credential_slice: :error)
    end

    # The FULL O(slice-types)-queries assertion (real caps, mixed flavors, constant
    # across N) lives in `Ezagent.Domain.AgentCredentialStatusTest` where the cap
    # machinery + cold-agent seeding already exist.
  end

  describe "unclassifiable" do
    test "an unregistered flavor → :unknown" do
      assert %{status: :unknown} = CredentialStatus.classify(agent_uri(), "not-registered", nil)
    end

    test "a nil flavor → :unknown" do
      assert %{status: :unknown} = CredentialStatus.classify(agent_uri(), nil, nil)
    end
  end
end
