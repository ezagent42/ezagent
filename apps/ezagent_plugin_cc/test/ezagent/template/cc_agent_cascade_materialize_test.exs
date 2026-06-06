defmodule Ezagent.PluginCc.Template.CcAgentCascadeMaterializeTest do
  @moduledoc """
  #17 cascade PR-2 — end-to-end wiring of the layered cascade materialize through the cc
  Template Class' `create_agent_config_dir/2` (spec §D4 layer-merge + §D6 secret-only copy
  + §5.1 grant TOCTOU + §7 atomic-replace). Proves the plugin delegates to the core
  `Ezagent.Agent.Materializer` correctly when the create chokepoint (PR-3) supplies the
  `"cascade"` inputs, while the single-reference path stays backward-compatible.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.Credential.GrantRow

  defp uniq, do: System.unique_integer([:positive])

  defp tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write!(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  setup do
    agent_uri = URI.new!("entity://team-a/agent/cc_cascade-#{uniq()}")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    source_uri = "entity://team-a/agent/alice-base-#{uniq()}"
    {:ok, _} = Ezagent.SnapshotStore.write(source_uri, %{}, kind_type: :agent)

    source_dir = tmp("cc-cred-src")
    File.write!(Path.join(source_dir, ".credentials.json"), "ALICE-TOKEN")
    # config files at the source MUST NOT be pulled (§D6).
    File.write!(Path.join(source_dir, "settings.json"), "SOURCE-SETTINGS")

    {:ok, _g} =
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: source_uri,
        approved_by: "entity://team-a/user/alice",
        approved_scope: source_uri,
        version: 1
      })

    {:ok, agent_uri: agent_uri, target: target, source_uri: source_uri, source_dir: source_dir}
  end

  defp cascade_tmpl(ctx, layer_dirs) do
    %{
      # required by create_agent_config_dir's outer guards (a non-empty ref + target).
      "config_dir" => List.first(layer_dirs).dir,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: layer_dirs,
        source_dir_for: fn _source_uri -> {:ok, ctx.source_dir} end
      }
    }
  end

  test "merges layers + copies ONLY the secret from the source + atomic-commits", ctx do
    base = tmp("cc-base")
    user = tmp("cc-user")
    write!(base, "settings.json", "BASE")
    write!(base, "plugins/base_only.json", "B")
    write!(user, "settings.json", "USER")
    write!(user, "plugins/user_only.json", "U")

    tmpl = cascade_tmpl(ctx, [%{dir: base}, %{dir: user}])

    assert {:ok, target} = CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
    assert target == ctx.target

    # whole-file-replace: user (higher) wins
    assert File.read!(Path.join(target, "settings.json")) == "USER"
    # directory-union
    assert File.read!(Path.join(target, "plugins/base_only.json")) == "B"
    assert File.read!(Path.join(target, "plugins/user_only.json")) == "U"
    # §D6: secret copied from the source
    assert File.read!(Path.join(target, ".credentials.json")) == "ALICE-TOKEN"
    # §D6: the source's CONFIG file was NOT pulled (settings.json is the merged USER one)
    refute File.read!(Path.join(target, "settings.json")) == "SOURCE-SETTINGS"
    # completion marker present
    assert File.exists?(Path.join(target, ".ezagent-config-complete"))
    # no orphan staging
    assert ctx.target
           |> Path.dirname()
           |> File.ls!()
           |> Enum.filter(&String.contains?(&1, ".staging-")) ==
             []
  end

  test "revoke-mid-start (TOCTOU) aborts before the dir is committed", ctx do
    base = tmp("cc-base")
    write!(base, "settings.json", "BASE")

    # Inject the revoke during source resolution (after fetch read v1, before revalidate).
    tmpl = %{
      "config_dir" => base,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: [%{dir: base}],
        source_dir_for: fn _ ->
          {:ok, _} = GrantRow.revoke(URI.to_string(ctx.agent_uri))
          {:ok, ctx.source_dir}
        end
      }
    }

    assert {:error, {:cascade_materialize_failed, :grant_changed}} =
             CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)

    # The target was NOT committed (no marker / no dir) — nothing launched with the
    # revoked secret. (target may not exist at all since there was no prior dir.)
    refute File.exists?(Path.join(ctx.target, ".ezagent-config-complete"))
  end

  test "missing mandatory control fails loud (G1)", ctx do
    base = tmp("cc-base")
    write!(base, "settings.json", "BASE")

    tmpl = %{
      "config_dir" => base,
      "allocated_config_dir" => ctx.target,
      "cascade" => %{
        layer_dirs: [%{dir: base, mandatory: ["hooks/required.sh"]}],
        source_dir_for: fn _ -> {:ok, ctx.source_dir} end
      }
    }

    assert {:error,
            {:cascade_materialize_failed, {:mandatory_control_missing, "hooks/required.sh"}}} =
             CcAgent.create_agent_config_dir(ctx.agent_uri, tmpl)
  end
end
