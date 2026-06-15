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
  5.5). The defense-in-depth that replaces the runtime cap is THIS static gate:
  every read of a SENSITIVE slice (the caps + credentials slices — `:identity`,
  `:api_keys`) by code OTHER than the slice's owning Behavior must be explicitly
  allowlisted with a justification. A new, un-reviewed credential/caps read then
  fails CI in code rather than silently leaking authority at runtime.

  Covers BOTH read mechanisms:
  - `reads_siblings([...])` (macro) AND a hand-written `def reads_siblings`.
  - `Kind.get_slice(_, :sensitive_key)` (the raw, un-cap-checked cross-Kind read).

  Scope (stated honestly): this gate covers the declared-sibling-read +
  `get_slice` surfaces for the two known sensitive slices. Adding a new sensitive
  slice means adding it to `@sensitive_slices` (and any legitimate readers to the
  allowlist). It does NOT claim to cover every conceivable data-flow leak.
  """

  # Sensitive slice key => the OWNING Behavior module (whose own reads are
  # exempt). Add a new credential/caps-bearing slice here when one is introduced.
  @sensitive_slices %{
    identity: "Ezagent.Behavior.Identity",
    api_keys: "Ezagent.Behavior.ApiKeys"
  }

  # Allowlist of sanctioned reads of a sensitive slice by NON-owner code, keyed
  # by `{path_suffix, slice_key}` with a one-line justification. Owner-Behavior
  # self-reads (the slice's owning module file) are exempt structurally and need
  # no entry. Grow ONLY with a reviewed justification.
  @allowlist %{
    # --- core framework (the cap engine itself legitimately reads identity) ---
    {"apps/ezagent_core/lib/ezagent/kind.ex", :identity} =>
      "default_holds_cap?/2 IS the CapBAC check — reads the principal's :identity caps",
    # --- identity domain (the sanctioned cap-read/grant facades) ---
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
      "the agent-api-keys management LiveView (cap-gated mount) renders the agent's own keys"
  }

  describe "scan_source/2 (the scanner, fixture-pinned)" do
    test "flags an un-allowlisted sensitive reads_siblings declaration" do
      src = """
      defmodule Some.Behavior.Rogue do
        use Ezagent.Lifecycle
        reads_siblings([:api_keys])
      end
      """

      assert [%{key: :api_keys, via: :reads_siblings}] =
               scan_source(src, "apps/x/lib/rogue.ex")
    end

    test "flags an un-allowlisted Kind.get_slice on a sensitive slice" do
      src = """
      defmodule Some.Behavior.Rogue do
        def peek(uri), do: Ezagent.Kind.get_slice(uri, :identity)
      end
      """

      assert [%{key: :identity, via: :get_slice}] = scan_source(src, "apps/x/lib/rogue.ex")
    end

    test "catches the hand-written `def reads_siblings` form (not just the macro)" do
      src = """
      defmodule Some.Behavior.Turnish do
        def reads_siblings, do: [:identity]
      end
      """

      assert [%{key: :identity, via: :reads_siblings}] =
               scan_source(src, "apps/x/lib/turnish.ex")
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

  test "the live source tree has no un-allowlisted sensitive cross-Behavior reads" do
    violations =
      scan_tree()
      |> Enum.reject(fn read -> owner_self_read?(read) or allowlisted?(read) end)

    assert violations == [], format_violations(violations)
  end

  # ── scanner ──────────────────────────────────────────────────────────────

  @sensitive_keys Map.keys(@sensitive_slices)

  # The core-framework files that DEFINE the read mechanisms (the
  # `reads_siblings` macro/callback + the `get_slice`/sibling-injection engine).
  # Their `@doc`/source text mentions `reads_siblings [:api_keys]` etc. as
  # examples of the API they implement — they are not Behavior CONSUMERS, so
  # they are excluded from the consumer-read scan. (A genuine sensitive read in
  # the cap engine itself — e.g. `Kind.default_holds_cap?/2` in kind.ex — is NOT
  # in this list and is allowlisted explicitly.)
  @mechanism_definition_files [
    "apps/ezagent_core/lib/ezagent/behavior.ex",
    "apps/ezagent_core/lib/ezagent/lifecycle.ex",
    "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
    "apps/ezagent_core/lib/ezagent/kind/runtime/context.ex"
  ]

  defp scan_source(source, file) when is_binary(source) do
    if Enum.any?(@mechanism_definition_files, &String.ends_with?(file, &1)) do
      []
    else
      code = strip_comments(source)
      reads_siblings_reads(code, file) ++ get_slice_reads(code, file)
    end
  end

  # Drop `#`-to-EOL line comments (so a `get_slice(_, :identity)` mentioned in a
  # comment isn't counted) while preserving `#{...}` interpolation.
  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/#(?!\{).*$/, &1, ""))
    |> Enum.join("\n")
  end

  defp reads_siblings_reads(source, file) do
    # Match both `reads_siblings([:a, :b])` / `reads_siblings [:a]` and a
    # hand-written `def reads_siblings, do: [:a]`. Capture the bracketed list,
    # then pull each `:atom` out of it.
    Regex.scan(~r/reads_siblings[^\[]*\[([^\]]*)\]/, source)
    |> Enum.flat_map(fn [_, list] -> atoms_in(list) end)
    |> Enum.filter(&(&1 in @sensitive_keys))
    |> Enum.map(fn key -> %{file: file, key: key, via: :reads_siblings} end)
  end

  defp get_slice_reads(source, file) do
    Regex.scan(~r/get_slice\([^,]+,\s*:([a-z_][a-z0-9_]*)\)/, source)
    |> Enum.map(fn [_, key] -> String.to_atom(key) end)
    |> Enum.filter(&(&1 in @sensitive_keys))
    |> Enum.map(fn key -> %{file: file, key: key, via: :get_slice} end)
  end

  defp atoms_in(list_src) do
    Regex.scan(~r/:([a-z_][a-z0-9_]*)/, list_src)
    |> Enum.map(fn [_, a] -> String.to_atom(a) end)
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

  # The owning Behavior's own file reading its own sensitive slice is exempt
  # (it is not a cross-Behavior read). Matched by the owner module's last
  # segment appearing in the file's basename (e.g. `Behavior.ApiKeys` ->
  # `api_keys.ex`).
  defp owner_self_read?(%{file: file, key: key}) do
    owner = Map.fetch!(@sensitive_slices, key)
    owner_file = owner |> String.split(".") |> List.last() |> Macro.underscore()
    Path.basename(file, ".ex") == owner_file
  end

  defp allowlisted?(%{file: file, key: key}) do
    Enum.any?(@allowlist, fn {{suffix, k}, _reason} ->
      k == key and String.ends_with?(file, suffix)
    end)
  end

  defp format_violations(violations) do
    lines =
      Enum.map_join(violations, "\n", fn %{file: f, key: k, via: via} ->
        "  - #{f} reads sensitive slice :#{k} via #{via}"
      end)

    """
    Un-allowlisted sensitive cross-Behavior slice read(s) found.

    #{lines}

    Sensitive slices (#{inspect(@sensitive_keys)}) carry caps/credentials. Under
    decision B (no runtime cap on in-process sibling reads) this gate is the
    defense-in-depth: a NON-owner read of one must be added to @allowlist in
    #{Path.relative_to(__ENV__.file, repo_root())} with a justification, after
    review. If you added a new sensitive slice, add it to @sensitive_slices too.
    """
  end

  defp repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end
end
