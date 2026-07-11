defmodule Ezagent.Invariants.CapIssuedBypassTrustKeysTest do
  @moduledoc """
  N1 (Phase-3 security review): pin the two trust-key properties the
  `cap_issued` runtime bypass relies on.

  `Ezagent.Kind.Runtime` step-5.5 authorizes an `IdentityAdmin` `:grant_cap`
  dispatch WITHOUT a matching cap whenever `ctx.cap_issued == true`
  (`kind/runtime.ex`, the first `cond` arm). That shortcut is only sound if:

    (a) an unauthorized grantor can never reach a `cap_issued` ctx. The
        chokepoint stamps `cap_issued` ONLY on the `Cap.issue/3` success
        branch of `prepare/4`, and `Cap.issue/3` fails closed for a grantor
        that holds no authority (grant authorization runs BEFORE the token is
        stamped and before any dispatch is built). So an unauthorized grant
        yields `{:error, _}` — no `cap_issued`, no dispatch; and

    (b) `cap_issued` cannot originate outside the grant chokepoint. No product
        code other than `Ezagent.Identity.Grant` writes the token, and only
        `Ezagent.Kind.Runtime` reads it — so an externally-built ctx
        (web/CLI/MCP/workspace) can never carry `cap_issued` (nor forge the
        `:vm_internal` absorb caller).

  Flip either property in product code and this file fails. `async: false`
  because property (a) swaps the process-global `Ezagent.Cap` authority loader.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}

  @grant_chokepoint "apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex"
  @runtime "apps/ezagent_core/lib/ezagent/kind/runtime.ex"

  describe "property (a): an unauthorized grantor cannot open the cap_issued bypass" do
    setup do
      previous = Application.get_env(:ezagent_core, Cap)
      loader = EzagentCore.Test.CapAuthorityLoaderStub

      # The grantor holds NO authority at all.
      Application.put_env(:ezagent_core, loader, MapSet.new())
      Application.put_env(:ezagent_core, Cap, authority_loader: loader)

      on_exit(fn ->
        if previous do
          Application.put_env(:ezagent_core, Cap, previous)
        else
          Application.delete_env(:ezagent_core, Cap)
        end

        Application.delete_env(:ezagent_core, loader)
      end)

      :ok
    end

    test "Cap.issue/3 fails closed for a grantor holding no authority" do
      issuer = Ezagent.URI.new!("entity://team-alpha/user/powerless")
      grantee = Ezagent.URI.new!("entity://team-alpha/user/grantee")
      target = Ezagent.URI.new!("entity://team-alpha/agent/managed")
      workspace = Ezagent.URI.new!("workspace://team-alpha")

      # A concrete, owner-scoped cap over an agent the powerless issuer neither
      # owns, manages, nor holds admin over: grant authorization must deny it.
      delegated = %Capability{
        kind: :agent,
        behavior: EzagentCore.Test.CapOwnedBehaviorStub,
        action: :read,
        instance: target,
        workspace_uri: workspace,
        granted_by: Ezagent.URI.new!("system://bootstrap"),
        granted_at: ~U[2020-01-01 00:00:00Z]
      }

      assert {:error, :grant_not_owner} =
               Cap.issue({:held_by, issuer}, grantee, delegated),
             "an authorityless grantor must fail Cap.issue/3 before any artifact " <>
               "or cap_issued ctx exists"
    end
  end

  test "the grant chokepoint stamps cap_issued only after Cap.issue/3 succeeds" do
    prepare = definition_source(@grant_chokepoint, :prepare, 4)

    # ISSUE precedes the token stamp: `maybe_mark_issued` is unreachable unless
    # `Cap.issue/3` returned `{:ok, cap2}`. This is what ties property (a)'s
    # "issue error => NO cap_issued / NO dispatch" to the chokepoint.
    assert ordered?(prepare, "Cap.issue(authorization, target, cap)", "maybe_mark_issued"),
           "prepare/4 must ISSUE before it stamps cap_issued"

    grant_src = source(@grant_chokepoint)

    assert grant_src =~
             "defp maybe_mark_issued(ctx, :grant_cap), do: Map.put(ctx, :cap_issued, true)",
           "grant is the only action that stamps cap_issued"

    assert grant_src =~ "defp maybe_mark_issued(ctx, :revoke_cap), do: ctx",
           "revoke must never stamp cap_issued"
  end

  test "property (b): cap_issued originates only at the grant chokepoint" do
    files_touching =
      "cap_issued"
      |> grep_product()
      |> Enum.map(&file_of/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert files_touching == Enum.sort([@grant_chokepoint, @runtime]),
           "cap_issued escaped its two homes (chokepoint writer + runtime reader):\n" <>
             Enum.join(files_touching, "\n")

    # The only WRITE of the token (`Map.put(ctx, :cap_issued, true)`) is at the
    # chokepoint. If any other product file sets it, an external ctx could forge
    # the runtime bypass.
    write_hits = grep_product(":cap_issued, true")

    assert write_hits != [] and
             Enum.all?(write_hits, &String.starts_with?(&1, @grant_chokepoint <> ":")),
           "cap_issued is written outside the grant chokepoint:\n" <>
             Enum.join(write_hits, "\n")

    # The runtime is the sole READER.
    read_hits = grep_product("Map.get(ctx, :cap_issued")

    assert read_hits != [] and
             Enum.all?(read_hits, &String.starts_with?(&1, @runtime <> ":")),
           "cap_issued is read outside Kind.Runtime step-5.5:\n" <>
             Enum.join(read_hits, "\n")
  end

  defp grep_product(pattern) do
    {output, status} =
      System.cmd(
        "grep",
        ["-rFn", pattern, Path.join(repo_root(), "apps"), "--include=*.ex"],
        stderr_to_stdout: false
      )

    if status > 1, do: raise("grep failed with exit #{status}")

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, repo_root() <> "/", ""))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  defp file_of(hit), do: hit |> String.split(":", parts: 2) |> hd()

  defp source(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  defp definition_source(relative, name, arity) do
    {:ok, ast} = relative |> source() |> Code.string_to_quoted()

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {kind, _meta, [head, _body]} = node, nil when kind in [:def, :defp] ->
          if definition_head?(head, name, arity),
            do: {node, Macro.to_string(node)},
            else: {node, nil}

        node, found ->
          {node, found}
      end)

    found || flunk("#{name}/#{arity} not found in #{relative}")
  end

  defp definition_head?({:when, _, [head | _guards]}, name, arity),
    do: definition_head?(head, name, arity)

  defp definition_head?({name, _, args}, name, arity) when is_list(args),
    do: length(args) == arity

  defp definition_head?(_head, _name, _arity), do: false

  defp ordered?(source, first, second) do
    case {:binary.match(source, first), :binary.match(source, second)} do
      {{first_at, _}, {second_at, _}} -> first_at < second_at
      _ -> false
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
