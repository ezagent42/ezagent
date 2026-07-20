defmodule Ezagent.Entity.SessionTemplateMembersTest do
  @moduledoc """
  team-routing-unification §3.7 (PR-7) — GATE (a): the extended
  SessionTemplate content (`members` / `prompt_templates` / `legends`)
  survives a write→read snapshot round-trip and the content version-hash
  extends over the new fields.

  PR-7 extends a SessionTemplate's `:template` content with three fields:

    * `members` — the members captured because `in_session_template: true`,
      each carrying its `role_name` and (for spawned agent members) a
      `source_template_uri` to recreate from;
    * `prompt_templates` — the named template map (§3.4);
    * `legends` — the §3.6 legend defs (`name => %{member_set,
      bound_rule_set, fold}`).

  `agent_slots` is no longer persisted in the content (PR-8 removes the
  slot tools; PR-7 stops writing it).

  Because `compute_version_hash/1` hashes `term_to_binary` over the whole
  content map (minus name/timestamps), and `Behavior.Template` `:write`
  stores the content verbatim (`{:set, :content, content}` — no key
  whitelist), the new fields are content-addressed + persisted with no
  schema change. These tests pin that contract.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SessionTemplate, User}
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])

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

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([signed_action_cap!(target, User.admin_uri())]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # A SessionTemplate `:template` content map carrying the PR-7 fields.
  defp team_content(name) do
    %{
      name: name,
      description: "a relay team",
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],

      # ── PR-7 extended content ───────────────────────────────────────
      members: [
        %{
          uri: Ezagent.URI.new!("entity://team-alpha/agent/cc_relay"),
          role_name: "relay-cc",
          in_session_template: true,
          source_template_uri: Ezagent.URI.new!("template://system/agent/cc")
        },
        %{
          uri: Ezagent.URI.new!("entity://team-alpha/user/watcher"),
          role_name: "watcher",
          in_session_template: true,
          source_template_uri: nil
        }
      ],
      prompt_templates: %{
        "telephone_hop" => "接龙：{body}（by {sender}）"
      },
      legends: %{
        "传话游戏" => %{
          member_set: ["relay-cc"],
          bound_rule_set: "telephone",
          fold: true
        }
      }
    }
  end

  describe "version-hash extends over the new PR-7 fields" do
    test "different members → different hash" do
      base = team_content("hash-members-#{uniq()}")
      changed = put_in(base, [:members, Access.at(0), :role_name], "relay-cc-2")

      refute SessionTemplate.compute_version_hash(base) ==
               SessionTemplate.compute_version_hash(changed),
             "members are part of the hashed content (§3.7)"
    end

    test "different prompt_templates → different hash" do
      base = team_content("hash-pt-#{uniq()}")
      changed = put_in(base, [:prompt_templates, "telephone_hop"], "DIFFERENT {body}")

      refute SessionTemplate.compute_version_hash(base) ==
               SessionTemplate.compute_version_hash(changed),
             "prompt_templates are part of the hashed content (§3.7)"
    end

    test "different legends → different hash" do
      base = team_content("hash-legend-#{uniq()}")
      changed = put_in(base, [:legends, "传话游戏", :fold], false)

      refute SessionTemplate.compute_version_hash(base) ==
               SessionTemplate.compute_version_hash(changed),
             "legends are part of the hashed content (§3.7)"
    end

    test "identical extended content → identical hash (deterministic, stable)" do
      a = team_content("hash-stable")
      b = team_content("hash-stable")

      assert SessionTemplate.compute_version_hash(a) ==
               SessionTemplate.compute_version_hash(b)
    end
  end

  describe "write→read round-trip of the extended content (GATE a)" do
    test "members / prompt_templates / legends survive persist + read unchanged" do
      name = "rt-#{uniq()}"
      content = team_content(name)
      hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
        )

      assert {:ok, %URI{} = uri} =
               SessionTemplate.persist_version(content, "workspace://team-alpha")

      track(uri)

      # Content-addressed URI carries the hash computed over the extended
      # content (so a member/template/legend change yields a new version).
      assert URI.to_string(uri) == "template://team-alpha/session/#{name}@#{hash}"

      # Round-trip: the extended fields come back byte-identical.
      assert {:ok, %{content: read_back}} = read(uri)
      assert read_back.members == content.members
      assert read_back.prompt_templates == content.prompt_templates
      assert read_back.legends == content.legends

      # The on_change snapshot row exists (durable persistence).
      assert Enum.any?(KindSnapshot.list_all(), fn %{uri: u} -> u == URI.to_string(uri) end)
    end

    test "the write-once :write guard accepts the extended content (hash agrees)" do
      # A correctly-formed persist (URI hash == content hash) must not trip
      # the write-once / hash-mismatch guard just because new keys were added.
      name = "rt-guard-#{uniq()}"
      content = team_content(name)
      hash = SessionTemplate.compute_version_hash(content)

      :ok =
        KindSnapshot.delete(
          URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
        )

      assert {:ok, uri} = SessionTemplate.persist_version(content, "workspace://team-alpha")
      track(uri)

      # Idempotent re-persist of identical content is a no-op success.
      assert {:ok, ^uri} = SessionTemplate.persist_version(content, "workspace://team-alpha")
    end
  end
end
