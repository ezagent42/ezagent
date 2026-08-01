defmodule Ezagent.Invariants.NoChatBehaviorTest do
  @moduledoc """
  MED-1 (chat→session rename, Allen 2026-06-12 — "use session naming, NO
  backward compatibility").

  The internal "Chat" Behavior concept does NOT exist any more — it was renamed
  to `Ezagent.ActionSet.Session` (behavior module + nested modules), its `:chat`
  state-slice key to `:session`, and every `chat.<action>` public spelling to
  `session.<action>`. This invariant locks that in: it scans every production
  (`apps/*/lib`) source file and FAILS if any OUR-behavior "Chat" spelling
  reappears.

  ## BOUNDARY — what is NOT flagged (external IM vocabulary, deliberately kept)

  This invariant scopes its regexes to OUR behavior — the `:chat` action atoms,
  the `Behavior.Chat` module, the `:chat` slice key. It does NOT flag the
  EXTERNAL-IM vocabulary that legitimately keeps the word "chat":

    * `chat_id` — Feishu/Slack's identifier for an external conversation (an
      external API field on `external_mirror_bindings` / `feishu_*` bindings /
      `InboundChatLookup`). Renaming it would break the integration.
    * Customer-facing "chat"/"chat feed" terminology in the external viewer SPA /
      `chat_feed*` (product-facing words shown to end users).
    * `system://chat-router` / `chat-reply` — named system-principal URIs (a
      separate persisted-identifier concept, like `chat_id`; not the `:chat`
      behavior/action/slice).
    * Free prose using the english word "chat" in a moduledoc/comment (stripped
      below before matching).

  The regexes therefore target STRUCTURAL spellings (`Behavior.Chat`,
  `with_action(_, :chat, _)`, `?action=chat.`, `state_slice: :chat`), never the
  bare substring "chat".

  Mirrors `lifecycle_persistence_access_test.exs`'s production-file scan idiom.
  """

  use ExUnit.Case, async: true

  # Each rule: a name, the forbidden-spelling regex (scoped to OUR behavior),
  # an allowlist of files that may legitimately match, and failure guidance.
  @rules [
    %{
      name: "the renamed Behavior module (Behavior.Chat)",
      # `Behavior.Chat` as a module reference, with or without the `Ezagent.`
      # prefix, and its nested modules (`Behavior.Chat.Delivery` etc). The
      # trailing boundary stops a false hit on a longer word.
      regex: ~r/\bBehavior\.Chat\b/,
      allowlist: [],
      guidance: "Use `Ezagent.ActionSet.Session` — the Chat Behavior was renamed."
    },
    %{
      name: "the :chat action spelling via with_action/3",
      regex: ~r/\bwith_action\([^,)]+,\s*:chat\s*,/,
      allowlist: [],
      guidance: "Use `:session` — `URI.with_action(uri, :session, <action>)`."
    },
    %{
      name: "the chat.<action> query spelling (?action=chat.<action>)",
      regex: ~r/\?action=chat\./,
      allowlist: [],
      guidance: "Use `?action=session.<action>` — the action namespace is `session`."
    },
    %{
      name: "the :chat state-slice key override (state_slice: :chat)",
      regex: ~r/state_slice:\s*:chat\b/,
      allowlist: [],
      guidance:
        "The slice key is `:session` (auto-derived from `Behavior.Session`) — " <>
          "no `:chat` override."
    }
  ]

  test "no internal Chat-behavior spelling remains in production code (chat→session rename)" do
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
           Internal "Chat" behavior spelling found in production code — the
           chat→session rename (Allen 2026-06-12, NO back-compat) requires the
           internal Chat concept to NOT exist:

           #{format_violations(violations)}

           Rename to the `session` spelling named in the guidance. If a match is
           genuinely the EXTERNAL-IM `chat_id` / `chat-router`
           vocabulary (NOT our behavior), the regex is too broad — tighten it,
           don't allowlist the boundary.
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

  # Strip single-line `#` comments so moduledoc / @doc prose describing the old
  # name (e.g. "renamed from `Behavior.Chat`") doesn't count as a live spelling.
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
      full_lib = Path.join([apps_root, "apps", app, "lib"])

      if File.dir?(full_lib) do
        full_lib
        |> list_ex_files()
        |> Enum.map(&Path.relative_to(&1, apps_root))
      else
        []
      end
    end)
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end
end
