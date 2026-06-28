defmodule Ezagent.Invariants.NoCustomerConceptTest do
  @moduledoc """
  The "customer" business concept is RETIRED from socialware (SPEC
  `retire-customer-concept`, 2026-06-26). "customer" was an AutoService business
  noun baked into the generic socialware domain; it is replaced by the generic
  **anon-user + membership** primitive (the same one the chat surface uses) and
  the neutral **external** vocabulary.

  This invariant is the COMPLETION GATE: it scans every production source file
  (`apps/*/lib`, `.ex` + the SPA `.js`/`.mjs`/`.css`) and FAILS if any STRUCTURAL
  "customer" business-concept SYMBOL reappears — a `Customer*` module, a
  `:customer_*` atom, the `socialware:customer` topic, the `/socialware/customer`
  route, or the retired `customer_app.js` / `customer.css` / `data-theme="customer"`
  / `socialware-customer-root` SPA assets.

  ## BOUNDARY — what is NOT flagged

    * The **legacy 301 redirect** in `router.ex` is the ONE intentional surviving
      `/socialware/customer` literal — it permanently redirects shipped links to
      `/socialware/external` (allowlisted below).
    * The english word "customer" used as a BUSINESS NOUN in free prose
      (moduledoc / comment) — e.g. "the customer page", "customers read the
      approved version". The regexes target STRUCTURAL spellings, never the bare
      substring "customer".

  Modelled on `no_chat_behavior_test.exs` (the chat→session retirement gate).
  """

  use ExUnit.Case, async: true

  @router_legacy_redirect "apps/ezagent_web/lib/ezagent_web/router.ex"

  # Each rule: a name, the forbidden STRUCTURAL-symbol regex, a per-rule
  # allowlist of files that may legitimately match, and failure guidance.
  @rules [
    %{
      name:
        "a Customer* business-concept module (Feed/Auth/Channel/Socket/Controller/Outbox/Delivery/Adapter)",
      regex: ~r/\bCustomer(Feed|Auth|Channel|Socket|Controller|Outbox|Delivery|FeedAdapter)\b/,
      allowlist: [],
      guidance:
        "Use the External*/Delivery* family (ExternalFeed, ExternalFeedSocket/" <>
          "Controller, SessionFeedChannel, DeliveryOutbox, ExternalDelivery) — the customer modules were retired."
    },
    %{
      name:
        "a :customer_* business-concept atom (:customer_visible / :customer_delivery / :allow_customer_feed)",
      regex: ~r/:customer_(visible|delivery|feed|outbox)\b|:allow_customer_feed\b/,
      allowlist: [],
      guidance:
        "Use :external_visible / :external_delivery — the :customer_* atoms were renamed; " <>
          ":allow_customer_feed was deleted with the dormant adapter."
    },
    %{
      name: ~s(the "socialware:customer" wire topic),
      regex: ~r/socialware:customer/,
      allowlist: [],
      guidance: ~s(Use "socialware:external" — the wire topic was renamed.)
    },
    %{
      name: "the /socialware/customer route literal",
      regex: ~r{/socialware/customer},
      # The router keeps the legacy paths ONLY as a 301 redirect to the renamed
      # /socialware/external route (back-compat for shipped links).
      allowlist: [@router_legacy_redirect],
      guidance:
        "Use /socialware/external — the route was renamed (a 301 in router.ex covers old links)."
    },
    %{
      name:
        "the retired customer SPA assets (customer_app.js / customer.css / data-theme=customer / socialware-customer-root)",
      regex: ~r/customer_app\.js|customer\.css|data-theme="customer"|socialware-customer-root/,
      allowlist: [],
      guidance: "Use viewer_app.js / viewer.css / data-theme=\"viewer\" / socialware-viewer-root."
    }
  ]

  test "the customer business concept is fully retired from socialware (no structural symbol remains)" do
    apps_root = Path.expand("../../../..", __DIR__)
    production_files = list_production_files(apps_root)

    violations =
      Enum.flat_map(@rules, fn rule ->
        production_files
        |> Enum.filter(fn rel_path ->
          rel_path not in rule.allowlist and
            rule.regex
            |> Regex.match?(strip_comments(Path.join(apps_root, rel_path)))
        end)
        |> Enum.map(fn rel_path -> {rule, rel_path} end)
      end)

    assert violations == [],
           """
           A retired "customer" business-concept SYMBOL reappeared in production
           code. The customer concept is retired (SPEC retire-customer-concept):

           #{format_violations(violations)}

           Rename to the neutral spelling named in the guidance. If a match is a
           genuinely incidental BUSINESS NOUN in prose (not a symbol), the regex is
           too broad — tighten it, do NOT allowlist a prose file.
           """
  end

  test "the retired customer modules + cap do not exist" do
    refute Code.ensure_loaded?(Ezagent.Socialware.CustomerAuth),
           "Ezagent.Socialware.CustomerAuth must be deleted (retired token auth)"

    refute Code.ensure_loaded?(Ezagent.Socialware.CustomerFeedAdapter),
           "Ezagent.Socialware.CustomerFeedAdapter must be deleted (dormant adapter)"

    refute Code.ensure_loaded?(Ezagent.Socialware.CustomerFeed),
           "Ezagent.Socialware.CustomerFeed was renamed to Ezagent.Socialware.ExternalFeed"

    assert Code.ensure_loaded?(Ezagent.Socialware.ExternalFeed),
           "Ezagent.Socialware.ExternalFeed (the renamed projection) must exist"
  end

  test "the stored visibility value is renamed (:customer_visible -> :external_visible)" do
    values = Ecto.Enum.values(Ezagent.Message, :visibility)
    refute :customer_visible in values, ":customer_visible must be retired from the enum"
    assert :external_visible in values, ":external_visible must be the external-read value"
  end

  test "the internal visibility value uses the new spelling" do
    apps_root = Path.expand("../../../..", __DIR__)
    retired = "operator" <> "_only"
    values = Ecto.Enum.values(Ezagent.Message, :visibility)

    refute Enum.any?(values, &(Atom.to_string(&1) == retired)),
           "#{retired} must be retired from the enum"
    assert :internal in values, ":internal must be the internal-read value"

    offenders =
      apps_root
      |> list_code_and_test_files()
      |> Enum.filter(fn rel_path ->
        Path.join(apps_root, rel_path)
        |> File.read!()
        |> String.contains?(retired)
      end)

    assert offenders == [],
           """
           The retired visibility spelling `#{retired}` reappeared in code or
           tests. Use `internal` for the all-info/internal projection.

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  defp format_violations(violations) do
    violations
    |> Enum.group_by(fn {rule, _} -> rule.name end, fn {rule, rel} -> {rel, rule.guidance} end)
    |> Enum.map_join("\n\n", fn {rule_name, entries} ->
      {_rel, guidance} = hd(entries)
      files = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      "  • #{rule_name}\n    → #{guidance}\n" <>
        Enum.map_join(files, "\n", fn f -> "      #{f}" end)
    end)
  end

  # Strip single-line `#` comments so a comment describing the retirement (e.g.
  # "the legacy /socialware/customer paths") doesn't count as a live symbol.
  # (Moduledoc/`@doc` prose is NOT stripped — but the regexes target structural
  # symbols, which no longer appear in prose after the rename.)
  defp strip_comments(full_path) do
    full_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp list_production_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      lib = Path.join([apps_root, "apps", app, "lib"])
      assets = Path.join([apps_root, "apps", app, "assets"])

      source_files(lib, apps_root) ++ asset_files(assets, apps_root)
    end)
  end

  defp list_code_and_test_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      app_root = Path.join([apps_root, "apps", app])

      [Path.join(app_root, "lib"), Path.join(app_root, "test")]
      |> Enum.flat_map(&source_files(&1, apps_root))
    end)
  end

  defp source_files(dir, apps_root) do
    if File.dir?(dir) do
      dir |> list_files([".ex"]) |> Enum.map(&Path.relative_to(&1, apps_root))
    else
      []
    end
  end

  # Scan the controller-rendered SPA assets too (the retired customer_app.js /
  # customer.css / theme / DOM-id), skipping node_modules + vendored deps.
  defp asset_files(dir, apps_root) do
    if File.dir?(dir) do
      dir
      |> list_files([".js", ".mjs", ".css"])
      |> Enum.reject(&String.contains?(&1, "/node_modules/"))
      |> Enum.reject(&String.contains?(&1, "/vendor/"))
      |> Enum.map(&Path.relative_to(&1, apps_root))
    else
      []
    end
  end

  defp list_files(dir, exts) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        entry in ["node_modules", "vendor"] -> []
        File.dir?(full) -> list_files(full, exts)
        Enum.any?(exts, &String.ends_with?(entry, &1)) -> [full]
        true -> []
      end
    end)
  end
end
