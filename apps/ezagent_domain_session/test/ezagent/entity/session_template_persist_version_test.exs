defmodule Ezagent.Entity.SessionTemplatePersistVersionTest do
  @moduledoc """
  Phase 7 completion PR-3 (SPEC §1.7 (a)) —
  `Ezagent.Entity.SessionTemplate.persist_version/2`.

  `persist_version/2` is the persistence helper standing on the
  Kind/`kind_snapshots` model: it spawns a SessionTemplate Kind at the
  content's computed-hash URI and dispatches `Behavior.Template`
  `:write` to populate the `:template` slice — which, because
  SessionTemplate is `{:snapshot, :on_change}`, writes a
  `kind_snapshots` row.

  Covers:

  - persisting content produces a resolvable
    `template://session/<ws>/<name>@<hash>` Kind with the content in
    its `:template` slice and a `kind_snapshots` row;
  - **idempotent duplicate-hash** — persisting identical content twice
    returns `{:ok, uri}` both times, no error, exactly one row;
  - a hash/URI-mismatched persist is rejected by the `:write`
    write-once guard.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SessionTemplate, User}

  defp uniq, do: System.unique_integer([:positive])

  # SessionTemplate Kinds live under EzagentDomainInstanceMessage.SessionTemplateSupervisor.
  # Terminate synchronously at test end so the Kind is gone before the
  # next test's sandbox owner is established.
  defp track(uri) do
    sup = EzagentDomainInstanceMessage.SessionTemplateSupervisor

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid), do: DynamicSupervisor.terminate_child(sup, pid)

        :error ->
          :ok
      end

      wait_until(fn -> KindRegistry.lookup(uri) == :error end)
    end)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp read(uri) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.read")
    admin = User.admin_uri()

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([signed_action_cap!(target, admin)]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp session_content(name) do
    # `agent_slots` is intentionally absent — it is no longer a content
    # field (codex MINOR / PR-8) and is stripped at persistence, so a
    # fixture carrying it would no longer round-trip verbatim.
    %{
      name: name,
      description: "a team",
      routing_rules: [],
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: Ezagent.URI.new!("entity://team-alpha/user/admin"),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  describe "persist_version/2 — the Kind-spawn + :write path" do
    test "persisting content produces a resolvable hash-addressed SessionTemplate Kind" do
      name = "pv-basic-#{uniq()}"
      content = session_content(name)
      expected_hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, expected_hash, workspace: "team-alpha"))
        )

      assert {:ok, %URI{} = uri} =
               SessionTemplate.persist_version(content, "workspace://team-alpha")

      track(uri)

      # The URI is the content-addressed template://session/<ws>/<name>@<hash>.
      assert URI.to_string(uri) == "template://team-alpha/session/#{name}@#{expected_hash}"

      # The Kind is alive and its :template slice holds the content.
      assert {:ok, %{content: ^content}} = read(uri)

      # The {:snapshot, :on_change} :write mutation wrote a kind_snapshots row.
      assert %KindSnapshot{kind_type: "session_template", workspace_uri: "workspace://team-alpha"} =
               KindSnapshot.get(URI.to_string(uri))
    end

    test "a bare workspace name (no scheme) is accepted" do
      name = "pv-bare-ws-#{uniq()}"
      content = session_content(name)
      hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
        )

      assert {:ok, %URI{} = uri} = SessionTemplate.persist_version(content, "team-alpha")
      track(uri)
      assert URI.to_string(uri) == "template://team-alpha/session/#{name}@#{hash}"
    end

    test "missing :name in the content map → {:error, :missing_template_name}" do
      content = session_content("ignored") |> Map.delete(:name)

      assert {:error, :missing_template_name} =
               SessionTemplate.persist_version(content, "workspace://team-alpha")
    end
  end

  describe "idempotent duplicate-hash persist (SPEC §1.7 (a))" do
    test "persisting identical content twice → {:ok, uri} both times, exactly one row" do
      name = "pv-idem-#{uniq()}"
      content = session_content(name)
      hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
        )

      assert {:ok, uri1} = SessionTemplate.persist_version(content, "workspace://team-alpha")
      track(uri1)

      # Second persist of the SAME content — same hash ⇒ same URI ⇒ the
      # Kind is already alive; the :write identical-retry no-ops. No error.
      assert {:ok, uri2} = SessionTemplate.persist_version(content, "workspace://team-alpha")

      assert uri1 == uri2

      # Exactly one snapshot row for the hash URI.
      assert %KindSnapshot{} = KindSnapshot.get(URI.to_string(uri1))
      all = KindSnapshot.list_all() |> Enum.filter(&(&1.uri == URI.to_string(uri1)))
      assert length(all) == 1

      # The content is still intact after the second (idempotent) write.
      assert {:ok, %{content: ^content}} = read(uri1)
    end
  end

  describe "hash/URI-mismatch rejection (the :write write-once guard)" do
    test "persisting into a pre-built Kind whose hash belongs to OTHER content is rejected" do
      name = "pv-mismatch-#{uniq()}"
      content = session_content(name)

      # Pre-spawn the SessionTemplate Kind at a URI whose @<hash>
      # segment is the hash of DIFFERENT content. persist_version
      # computes the hash of `content` and builds its OWN URI from it,
      # so to force a mismatch we dispatch :write against the wrong-hash
      # Kind directly — the same write-once guard persist_version
      # relies on.
      wrong_hash =
        SessionTemplate.compute_version_hash(%{content | description: "different"})

      wrong_uri = SessionTemplate.build_uri(name, wrong_hash, workspace: "team-alpha")
      :ok = KindSnapshot.delete(URI.to_string(wrong_uri))

      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(wrong_uri)
      track(wrong_uri)

      target = Ezagent.URI.new!("#{URI.to_string(wrong_uri)}?action=template.write")
      admin = User.admin_uri()

      result =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{content: content},
          ctx: %{
            caller: admin,
            authenticated_principal: admin,
            caps: MapSet.new([signed_action_cap!(target, admin)]),
            reply: {:caller_inbox, self()}
          }
        })

      # The :write hash-check rejects content whose hash disagrees with
      # the Kind URI's @<hash> segment — a stray write cannot corrupt a
      # hash-addressed version.
      assert {:error, :hash_mismatch} = result
    end

    test "persist_version itself is self-consistent — its URI always matches its content hash" do
      # persist_version builds the URI from compute_version_hash(content),
      # so the :write hash-check inside it always passes for a
      # well-formed call. This proves the happy path is never a
      # false-positive mismatch.
      name = "pv-consistent-#{uniq()}"
      content = session_content(name)
      hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
        )

      assert {:ok, uri} = SessionTemplate.persist_version(content, "workspace://team-alpha")
      track(uri)
      assert String.ends_with?(URI.to_string(uri), "@#{hash}")
    end
  end
end
