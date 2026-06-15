defmodule Ezagent.Invariants.SensitiveSliceReadTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Task #56 (decision B) gate — sensitive cross-Behavior slice reads must be
  allowlisted.

  ## Why this gate exists

  Decision B (2026-06-15): a Kind hosts several Behaviors in one process, and an
  in-process sibling read (Behavior A reading Behavior B's slice) is treated as
  STRUCTURALLY authorized — no runtime cap check (the reader and the data share
  one Kind/entity trust domain, and INVOCATION stays cap-gated at dispatch step
  5.5/5.6). The defense-in-depth that replaces the runtime cap is THIS static
  gate: every read of a SENSITIVE slice (the caps + credentials slices —
  `:identity`, `:api_keys`) by code OTHER than the slice's owning Behavior must
  be explicitly allowlisted with a justification. A new, un-reviewed
  credential/caps read then fails CI in code rather than silently leaking
  authority at runtime.

  ## What it catches (AST-based — no regex false-pass holes)

  - The declared-sibling-read mechanism in BOTH forms AND both callbacks:
    `reads_siblings([...])` / `def reads_siblings` (Lifecycle) and the legacy
    `reads_sibling_slices([...])` / `def reads_sibling_slices` (still unioned
    into `ctx.siblings` by `Behavior.reads_siblings_of/1`).
  - `*.get_slice(uri, key)` (the raw, un-cap-checked cross-Kind read), qualified
    or bare. A LITERAL sensitive `key` is flagged; a NON-LITERAL `key`
    (`k = :api_keys; Kind.get_slice(uri, k)`) is flagged FAIL-CLOSED as
    `:__dynamic__` and must be allowlisted, since `get_slice/2` accepts any atom.
  - Owner exemption is by the file's `defmodule` (exact owner MODULE), not the
    filename — a non-owner file named `identity.ex` cannot bypass.

  ## Scope (stated honestly)

  Covers the `reads_siblings`/`reads_sibling_slices` declarations + the
  `get_slice/2` read surface for the slices in `@sensitive_slices`. The cap/slice
  ENGINE files (`@mechanism_definition_files`, incl. `kind.ex` which defines
  `get_slice` + `default_holds_cap?`) are excluded — they implement the
  mechanism, they are not Behavior consumers. Adding a new sensitive slice means
  adding it to `@sensitive_slices`. It does not claim to cover every conceivable
  data-flow leak.
  """

  # Sensitive slice key => the OWNING Behavior MODULE (whose own reads are exempt,
  # matched by exact module name — NOT filename). Add a new credential/caps-bearing
  # slice here when one is introduced.
  @sensitive_slices %{
    identity: "Ezagent.Behavior.Identity",
    api_keys: "Ezagent.Behavior.ApiKeys"
  }

  @sensitive_keys Map.keys(@sensitive_slices)

  # Sentinel key for a fail-closed non-literal `get_slice/2`/sibling-read arg
  # (the slice key is only known at runtime, so it COULD be sensitive).
  @dynamic_key :__dynamic__

  # Core-framework files that DEFINE the read mechanisms (the `reads_siblings`/
  # `reads_sibling_slices` macros + callbacks, the `get_slice` definition + the
  # sibling-injection engine + the cap engine). They mention/implement the API;
  # they are not Behavior CONSUMERS, so they are excluded from the consumer scan.
  @mechanism_definition_files [
    "apps/ezagent_core/lib/ezagent/behavior.ex",
    "apps/ezagent_core/lib/ezagent/behavior/introspection.ex",
    "apps/ezagent_core/lib/ezagent/lifecycle.ex",
    "apps/ezagent_core/lib/ezagent/kind.ex",
    "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
    "apps/ezagent_core/lib/ezagent/kind/runtime/context.ex"
  ]

  # Sanctioned reads of a sensitive slice by NON-owner code, keyed by
  # `{path_suffix, key}` (key is a sensitive atom OR `:__dynamic__`) with a
  # one-line justification. Owner-Behavior self-reads (matched by module) are
  # exempt structurally and need no entry. Grow ONLY with a reviewed justification.
  @allowlist %{
    # --- identity domain: the sanctioned caps read/grant facade ---
    {"apps/ezagent_domain_identity/lib/ezagent/identity.ex", :identity} =>
      "Identity facade list_caps_for/grant authority resolution — the sanctioned caps read path",
    # --- operator CLI ---
    {"apps/ezagent_cli/lib/ezagent_cli/dispatch.ex", :identity} =>
      "operator CLI caps inspection (authenticated operator tooling)",
    # --- agent domain: CurlAgent funds its outbound HTTP call with its own creds ---
    {"apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex", :api_keys} =>
      "CurlAgent reads sibling :api_keys to fund its outbound call (same agent's own credential)",
    # --- identity domain: config evolution mutates config under the agent's own authority ---
    {"apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex", :identity} =>
      "ConfigEvolve reads sibling :identity caps to evolve config under the agent's own authority",
    # --- curl template + api-keys LiveView: credential provisioning/management surfaces ---
    {"apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex", :api_keys} =>
      "curl Template Class copies a source agent's :api_keys at provisioning (cap-gated create flow)",
    {"apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_api_keys_live.ex", :api_keys} =>
      "the agent-api-keys management LiveView (cap-gated mount) renders the agent's own keys",
    # --- dynamic-key get_slice: the generic URI-query slice resolver ---
    {"apps/ezagent_domain_session/lib/ezagent_domain_instance_message/uri_query_resolvers.ex",
     @dynamic_key} =>
      "generic UriQuery slice resolver — slice_key derived from a parsed (cap-gated dispatch) URI query"
  }

  describe "scan_source/2 (AST scanner, fixture-pinned)" do
    test "flags an un-allowlisted sensitive reads_siblings declaration (macro form)" do
      src = """
      defmodule Some.Behavior.Rogue do
        use Ezagent.Lifecycle
        reads_siblings([:api_keys])
      end
      """

      assert [%{key: :api_keys, via: :reads_siblings, module: "Some.Behavior.Rogue"}] =
               scan_source(src, "apps/x/lib/rogue.ex")
    end

    test "catches the hand-written `def reads_siblings` form" do
      src = """
      defmodule Some.Behavior.Turnish do
        def reads_siblings, do: [:identity]
      end
      """

      assert [%{key: :identity, via: :reads_siblings}] = scan_source(src, "apps/x/lib/t.ex")
    end

    test "catches the LEGACY reads_sibling_slices callback (still runtime-live)" do
      src = """
      defmodule Some.Behavior.Legacy do
        def reads_sibling_slices, do: [:api_keys]
      end
      """

      assert [%{key: :api_keys, via: :reads_sibling_slices}] =
               scan_source(src, "apps/x/lib/legacy.ex")
    end

    test "flags a Kind.get_slice on a sensitive slice (qualified + bare)" do
      qualified = """
      defmodule Some.Behavior.A do
        def peek(uri), do: Ezagent.Kind.get_slice(uri, :identity)
      end
      """

      bare = """
      defmodule Some.Behavior.B do
        import Ezagent.Kind
        def peek(uri), do: get_slice(uri, :api_keys)
      end
      """

      assert [%{key: :identity, via: :get_slice}] = scan_source(qualified, "apps/x/lib/a.ex")
      assert [%{key: :api_keys, via: :get_slice}] = scan_source(bare, "apps/x/lib/b.ex")
    end

    test "FAIL-CLOSED: a non-literal get_slice key is flagged :__dynamic__" do
      src = """
      defmodule Some.Behavior.Dyn do
        def peek(uri, key), do: Ezagent.Kind.get_slice(uri, key)
      end
      """

      assert [%{key: :__dynamic__, via: :get_slice}] = scan_source(src, "apps/x/lib/dyn.ex")
    end

    test "does NOT flag reads of NON-sensitive slices" do
      src = """
      defmodule Some.Behavior.Benign do
        use Ezagent.Lifecycle
        reads_siblings([:sandbox, :publisher])
        def peek(uri), do: Ezagent.Kind.get_slice(uri, :surface)
      end
      """

      assert [] = scan_source(src, "apps/x/lib/benign.ex")
    end
  end

  describe "owner_self_read?/1 (owner exemption is by MODULE, not filename)" do
    test "the owning Behavior module reading its own slice is exempt" do
      read = %{file: "apps/x/lib/api_keys.ex", module: "Ezagent.Behavior.ApiKeys", key: :api_keys}
      assert owner_self_read?(read)
    end

    test "a NON-owner module in a file named like the owner is NOT exempt" do
      # filename collides (api_keys.ex) but the module is not the owner Behavior
      read = %{file: "apps/x/lib/api_keys.ex", module: "Some.Other.ApiKeys", key: :api_keys}
      refute owner_self_read?(read)
    end

    test "a dynamic-key read is never owner-exempt" do
      refute owner_self_read?(%{file: "x", module: "Ezagent.Behavior.ApiKeys", key: @dynamic_key})
    end
  end

  test "the live source tree has no un-allowlisted sensitive cross-Behavior reads" do
    violations =
      scan_tree()
      |> Enum.reject(fn read -> owner_self_read?(read) or allowlisted?(read) end)

    assert violations == [], format_violations(violations)
  end

  # ── AST scanner ───────────────────────────────────────────────────────────

  defp scan_source(source, file) when is_binary(source) do
    if mechanism_file?(file) do
      []
    else
      case Code.string_to_quoted(source) do
        {:ok, ast} -> scan_ast(ast, file)
        {:error, _} -> []
      end
    end
  end

  defp mechanism_file?(file),
    do: Enum.any?(@mechanism_definition_files, &String.ends_with?(file, &1))

  defp scan_ast(ast, file) do
    module = top_module(ast)

    {_ast, reads} =
      Macro.prewalk(ast, [], fn node, acc -> {node, node_reads(node, file, module) ++ acc} end)

    Enum.reverse(reads)
  end

  # reads_siblings([...]) / reads_sibling_slices([...]) macro-call form
  defp node_reads({form, _, [arg]}, file, module)
       when form in [:reads_siblings, :reads_sibling_slices] do
    sibling_reads(form, arg, file, module)
  end

  # def reads_siblings, do: [...] / def reads_sibling_slices, do: [...] (0-arity)
  defp node_reads({def_kw, _, [{form, _, ctx}, [{:do, body} | _]]}, file, module)
       when def_kw in [:def, :defp] and form in [:reads_siblings, :reads_sibling_slices] and
              not is_list(ctx) do
    sibling_reads(form, body, file, module)
  end

  # Qualified `*.get_slice(uri, key)` (e.g. Ezagent.Kind.get_slice/Kind.get_slice)
  defp node_reads({{:., _, [_mod, :get_slice]}, _, [_uri, key]}, file, module) do
    get_slice_read(key, file, module)
  end

  # Bare `get_slice(uri, key)` (e.g. after `import Ezagent.Kind`)
  defp node_reads({:get_slice, _, [_uri, key]}, file, module) do
    get_slice_read(key, file, module)
  end

  defp node_reads(_node, _file, _module), do: []

  defp sibling_reads(form, arg, file, module) do
    via = if form == :reads_sibling_slices, do: :reads_sibling_slices, else: :reads_siblings

    cond do
      is_list(arg) and Enum.all?(arg, &is_atom/1) ->
        arg
        |> Enum.filter(&(&1 in @sensitive_keys))
        |> Enum.map(&%{file: file, module: module, key: &1, via: via})

      true ->
        # non-literal declaration list — fail closed
        [%{file: file, module: module, key: @dynamic_key, via: via}]
    end
  end

  defp get_slice_read(key, file, module) when is_atom(key) do
    if key in @sensitive_keys,
      do: [%{file: file, module: module, key: key, via: :get_slice}],
      else: []
  end

  defp get_slice_read(_non_literal, file, module) do
    [%{file: file, module: module, key: @dynamic_key, via: :get_slice}]
  end

  defp top_module(ast) do
    {_ast, name} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil ->
          {node, Enum.map_join(parts, ".", &Atom.to_string/1)}

        node, acc ->
          {node, acc}
      end)

    name
  end

  defp scan_tree do
    repo_root()
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn abs ->
      rel = Path.relative_to(abs, repo_root())
      abs |> File.read!() |> scan_source(rel)
    end)
  end

  # Exempt ONLY when the read's enclosing module is the slice's exact owner
  # Behavior module (never for a dynamic key).
  defp owner_self_read?(%{key: @dynamic_key}), do: false

  defp owner_self_read?(%{key: key, module: module}) do
    Map.get(@sensitive_slices, key) == module
  end

  defp allowlisted?(%{file: file, key: key}) do
    Enum.any?(@allowlist, fn {{suffix, k}, _reason} ->
      k == key and String.ends_with?(file, suffix)
    end)
  end

  defp format_violations(violations) do
    lines =
      Enum.map_join(violations, "\n", fn %{file: f, key: k, via: via, module: m} ->
        "  - #{f} (#{m}) reads sensitive slice #{inspect(k)} via #{via}"
      end)

    """
    Un-allowlisted sensitive cross-Behavior slice read(s) found.

    #{lines}

    Sensitive slices (#{inspect(@sensitive_keys)}) carry caps/credentials. Under
    decision B (no runtime cap on in-process sibling reads) this gate is the
    defense-in-depth: a NON-owner read of one must be added to @allowlist with a
    justification, after review. A `#{inspect(@dynamic_key)}` key means a
    non-literal `get_slice/2`/sibling-read arg (fail-closed — the runtime key
    could be sensitive). If you added a new sensitive slice, add it to
    @sensitive_slices too.
    """
  end

  defp repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end
end
