defmodule EzagentCore.Invariants.WildcardCapAuthorizesConcreteNeededTest do
  @moduledoc """
  Wildcard-cap-fix regression lock (2026-05-26) — three pure-data
  invariants the dispatch step 5.5 cap check MUST honor:

  1. **URI struct normalization** — `Ezagent.Capability.matches?/2`
     accepts URIs equivalently regardless of whether the producer
     used `URI.parse/1` (legacy, sets `authority`) or `URI.new!/1`
     (modern, leaves `authority: nil`). Both stringify identically;
     `matches?/2` MUST treat them as equal at the `instance` axis
     just as `workspace_match?/2` already does at the `workspace_uri`
     axis. The pre-fix `defp instance_match?(same, same)` clause
     pattern-matched struct equality, silently denying every narrow
     cap with a concrete URI instance — the precise regression
     unmasked by PR-CC-2-v2 (#354) + #358.

  2. **Wildcard cap authorizes any concrete needed cap** — a holder
     of `%Capability{kind: :any, behavior: :any, instance: :any,
     workspace_uri: :any}` passes step 5.5 for ANY concrete needed
     cap shape. This was the symptom Allen first reported: linyilun
     has the wildcard in `users.caps_json` but every dispatch denies.
     The denial root cause was actually (1) above blocking the
     intermediate `Identity.:list_caps` call inside `Identity.list_caps_for/1`
     (so LV ctx.caps came back empty), but the wildcard-grants-all
     property is a structural invariant worth a regression lock too.

  3. **Self-Identity cap authorizes `:list_caps` against own URI** —
     the slice-baseline cap that `Behavior.Identity.add_owner_identity_cap/2`
     mints at slice init MUST match the dispatch-time needed cap
     produced by step 5.5's `resolve_required_cap` substitution.
     This is the cap-shape contract between init_slice and the
     runtime substitution — both sides must produce structurally
     equal field values (kind, behavior, instance, workspace_uri).
     The pre-fix URI struct equality bug broke THIS pairing first;
     the rest of the cascade followed.

  These are PURE assertions on `Capability.matches?/2` semantics —
  no Repo, no GenServer, no boot. Async-safe.

  See:
  - `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §3
    (Kind.holds_cap? / Capability.matches? contract)
  - forensic note: docs/notes/wildcard-cap-fix-2026-05-26.md (if added)
  """

  use ExUnit.Case, async: true

  describe "URI struct normalization (invariant 1)" do
    test "URI.parse/1 and URI.new!/1 instances are treated as equal by matches?" do
      # Same canonical URI, two producers — one legacy (sets
      # `authority: 'user'`), one modern (leaves `authority: nil`).
      legacy = URI.parse("entity://user/system/linyilun")
      modern = URI.new!("entity://user/system/linyilun")

      assert legacy.authority == "user",
             "test fixture invariant: URI.parse/1 must set the deprecated `authority` field; if Elixir ever changes this, the regression lock no longer protects what it claims to."

      assert is_nil(modern.authority),
             "test fixture invariant: URI.new!/1 must leave `authority: nil`."

      refute legacy == modern,
             "test fixture invariant: the two URI structs must NOT be struct-equal — that's the exact divergence that broke matches?/2 pre-fix."

      held =
        cap(
          kind: :user,
          behavior: Ezagent.Behavior.Identity,
          instance: legacy,
          workspace_uri: URI.parse("workspace://system")
        )

      needed = %{
        kind: :user,
        behavior: Ezagent.Behavior.Identity,
        instance: modern,
        workspace_uri: URI.new!("workspace://system")
      }

      assert Ezagent.Capability.matches?(held, needed),
             "matches?/2 MUST treat URI.parse/1- and URI.new!/1-produced URIs as equivalent at the `instance` axis — string-equal URIs are semantically the same cap target regardless of which parser produced the struct."
    end

    test "matches?/2 still rejects URIs with different canonical strings" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.Behavior.Identity,
          instance: URI.new!("session://default/system/main"),
          workspace_uri: URI.new!("workspace://system")
        )

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Identity,
        # Different instance — different name part.
        instance: URI.new!("session://default/system/other"),
        workspace_uri: URI.new!("workspace://system")
      }

      refute Ezagent.Capability.matches?(held, needed),
             "matches?/2 MUST still reject genuinely different URIs — fixing the struct-equality bug must not make every URI match every other URI."
    end
  end

  describe "wildcard cap authorizes any concrete needed cap (invariant 2)" do
    test "the bootstrap wildcard cap matches workspace.create_agent" do
      wildcard =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any
        )

      needed = %{
        kind: :workspace,
        # Use a real Behavior module so the kind/behavior axes carry
        # production-shape values; the wildcard cap must match regardless.
        behavior: Ezagent.Behavior.Identity,
        instance: URI.new!("workspace://system"),
        workspace_uri: URI.new!("workspace://system")
      }

      assert Ezagent.Capability.matches?(wildcard, needed)
    end

    test "the wildcard cap matches identity.list_caps against a user URI" do
      wildcard =
        cap(
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any
        )

      user_uri = URI.new!("entity://user/system/linyilun")

      needed = %{
        kind: :user,
        behavior: Ezagent.Behavior.Identity,
        instance: user_uri,
        workspace_uri: URI.new!("workspace://system")
      }

      assert Ezagent.Capability.matches?(wildcard, needed)
    end

    test "the wildcard cap matches identity.list_caps when the held cap used URI.parse/1" do
      # The wildcard cap's instance is `:any`, so the URI struct
      # divergence (parse vs new) does NOT exercise the URI axis at
      # all. The match is via the `instance_match?(:any, _)` clause.
      # This test exists to lock in that the wildcard short-circuit
      # is independent of any URI normalization quirks.
      wildcard =
        %Ezagent.Capability{
          kind: :any,
          behavior: :any,
          instance: :any,
          workspace_uri: :any,
          # Granted_by uses URI.parse/1 (legacy) — irrelevant to
          # match logic but mirrors the from_map deserialization path.
          granted_by: URI.parse("entity://user/system/admin"),
          granted_at: ~U[2026-05-25 02:00:24Z]
        }

      needed = %{
        kind: :workspace,
        behavior: Ezagent.Behavior.Identity,
        instance: URI.new!("workspace://system"),
        workspace_uri: URI.new!("workspace://system")
      }

      assert Ezagent.Capability.matches?(wildcard, needed)
    end
  end

  describe "self-Identity cap pairing (invariant 3)" do
    test "the slice's self-Identity cap matches the dispatch-substituted needed cap for :list_caps" do
      # Mirror the construction in `Ezagent.Behavior.Identity.add_owner_identity_cap/2`:
      # - kind is derived from the URI's entity host (:user / :agent)
      # - behavior is `Ezagent.Behavior.Identity`
      # - instance is `Ezagent.URI.instance(uri)`
      # - workspace_uri is `Ezagent.Capability.workspace_of(uri)`
      #
      # `Ezagent.URI.instance/1` operates on the URI struct as-given.
      # In production the held cap's `uri` came from `args[:uri]`
      # passed to `Kind.spawn` — which (depending on caller path) may
      # have been produced by `URI.parse/1` OR `URI.new!/1`. Both
      # paths must produce a cap whose `instance` matches the
      # dispatch-time substituted instance.
      user_uri_parse = URI.parse("entity://user/system/linyilun")
      user_uri_new = URI.new!("entity://user/system/linyilun")

      held_from_parse_path =
        cap(
          kind: :user,
          behavior: Ezagent.Behavior.Identity,
          instance: Ezagent.URI.instance(user_uri_parse),
          workspace_uri: Ezagent.Capability.workspace_of(user_uri_parse)
        )

      held_from_new_path =
        cap(
          kind: :user,
          behavior: Ezagent.Behavior.Identity,
          instance: Ezagent.URI.instance(user_uri_new),
          workspace_uri: Ezagent.Capability.workspace_of(user_uri_new)
        )

      # Dispatch step 5.5 substitutes the needed cap from
      # `Behavior.Identity.required_caps/0` (`cap(:any, Identity, :list_caps)`)
      # against the action target. Mirror the substitution:
      target = URI.new!("entity://user/system/linyilun?action=identity.list_caps")

      needed = %{
        kind: :user,
        behavior: Ezagent.Behavior.Identity,
        instance: Ezagent.URI.instance(target),
        workspace_uri: Ezagent.Capability.workspace_of(target)
      }

      assert Ezagent.Capability.matches?(held_from_parse_path, needed),
             "self-Identity cap (held instance from URI.parse/1) must match the dispatch-substituted needed cap — this is the bug that denied :list_caps for linyilun pre-fix."

      assert Ezagent.Capability.matches?(held_from_new_path, needed),
             "self-Identity cap (held instance from URI.new!/1) must match the dispatch-substituted needed cap — symmetric to the parse path."
    end
  end

  # Small helper — fills the mandatory `granted_by` / `granted_at`
  # fields with sentinel values so tests can focus on the four
  # match-axes.
  defp cap(opts) do
    %Ezagent.Capability{
      kind: Keyword.fetch!(opts, :kind),
      behavior: Keyword.fetch!(opts, :behavior),
      instance: Keyword.fetch!(opts, :instance),
      workspace_uri: Keyword.fetch!(opts, :workspace_uri),
      granted_by: :plugin_declared,
      granted_at: :compile_time
    }
  end
end
