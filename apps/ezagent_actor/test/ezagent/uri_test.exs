defmodule Ezagent.URITest do
  use ExUnit.Case, async: true

  # URI hardening (2026-05-30) — "address silent errors unacceptable"
  # (Allen). These cases exercise the canonical/non-canonical divergence
  # that is the root of the silent-address-error class. Several deliberately
  # construct the NON-canonical (URI.parse, authority-bearing) form as a
  # fixture to prove the guard rejects it; those lines carry the
  # `# uri-canonical-allow` suppression so the lint gate doesn't fight the
  # regression tests it protects.
  @ezagent_scheme_examples [
    "entity://system/user/admin",
    "entity://team-alpha/agent/cc_demo",
    "entity://team-alpha/worker/slot-1",
    "session://system/default/main",
    "session://team-alpha/template-x/main?action=session.send",
    "template://system/agent/cc-orchestrator",
    "template://team-alpha/session/code-review",
    "resource://team-alpha/uploads/file-abc",
    "workspace://team-alpha",
    "workspace://system",
    "system://routing/default",
    "system://bootstrap/default"
  ]

  describe "bare_principal?/1 — the centralized fail-closed caller-identity gate (P4)" do
    test "accepts a canonical user/agent/worker principal" do
      assert Ezagent.URI.bare_principal?(Ezagent.URI.entity(:team_alpha, :user, "alice"))
      assert Ezagent.URI.bare_principal?(Ezagent.URI.entity(:team_alpha, :agent, "bot"))
      assert Ezagent.URI.bare_principal?(Ezagent.URI.entity(:team_alpha, :worker, "slot-1"))
    end

    test "rejects nil / atoms / non-URI" do
      refute Ezagent.URI.bare_principal?(nil)
      refute Ezagent.URI.bare_principal?(:any)
      refute Ezagent.URI.bare_principal?(:system)
      refute Ezagent.URI.bare_principal?("entity://x")
      refute Ezagent.URI.bare_principal?(%{not: "a uri"})
    end

    test "rejects a non-entity scheme even if structurally a %URI{}" do
      refute Ezagent.URI.bare_principal?(Ezagent.URI.session(:team_alpha, :default, "s1"))
      refute Ezagent.URI.bare_principal?(Ezagent.URI.workspace(:team_alpha))
    end

    test "rejects a non-canonical (URI.parse authority-bearing) entity URI" do
      non_canonical = URI.parse("entity://team-alpha/user/alice")
      assert non_canonical.authority != nil
      refute Ezagent.URI.bare_principal?(non_canonical)
    end

    test "rejects crafted entity URIs with extraneous fields" do
      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               path: "/user/alice",
               query: "action=x"
             })

      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               path: "/user/alice",
               fragment: "x"
             })

      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               userinfo: "evil",
               path: "/user/alice"
             })

      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               port: 443,
               path: "/user/alice"
             })

      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               path: "/user/alice/auth/login"
             })

      refute Ezagent.URI.bare_principal?(%URI{
               scheme: "entity",
               host: "team-alpha",
               path: "/notatype/x"
             })
    end
  end

  describe "canonical?/1 + canonical!/1 — the silent-error guard (URI hardening 2026-05-30)" do
    test "new!/1 output is canonical for every Ezagent scheme" do
      for s <- @ezagent_scheme_examples do
        uri = Ezagent.URI.new!(s)
        assert Ezagent.URI.canonical?(uri), "new!/1 produced non-canonical URI for #{s}"
        assert uri.authority == nil, "expected authority:nil for #{s}"
      end
    end

    test "URI.parse/1 output is NON-canonical (the bug fixture)" do
      for s <- @ezagent_scheme_examples do
        legacy = URI.parse(s)
        refute Ezagent.URI.canonical?(legacy), "URI.parse should be non-canonical for #{s}"
        assert legacy.authority != nil, "URI.parse precondition: authority populated for #{s}"
      end
    end

    test "canonical and authority-bearing structs are NOT == (the silent mismatch)" do
      for s <- @ezagent_scheme_examples do
        canon = Ezagent.URI.new!(s)
        legacy = noncanonical_uri(s)
        refute canon == legacy, "canon == legacy for #{s} — would mask the bug"
        # ...but they DO to_string to identical bytes (why it's silent).
        assert URI.to_string(canon) == URI.to_string(legacy)
      end
    end

    test "canonical!/1 returns the URI unchanged when canonical" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      assert Ezagent.URI.canonical!(uri) == uri
    end

    test "canonical!/1 RAISES on a non-canonical (authority-bearing) %URI{}" do
      legacy = noncanonical_uri("entity://system/user/admin")

      assert_raise ArgumentError, ~r/non-canonical %URI\{\}/, fn ->
        Ezagent.URI.canonical!(legacy)
      end
    end

    test "canonical!/1 error names the divergent authority value (loud, attributable)" do
      legacy = noncanonical_uri("entity://team-alpha/agent/cc_demo")

      err =
        assert_raise ArgumentError, fn -> Ezagent.URI.canonical!(legacy) end

      assert Exception.message(err) =~ "authority: \"team-alpha\""
      assert Exception.message(err) =~ "Ezagent.URI.new!/1"
    end

    test "canonical!/1 raises a clear message on non-%URI{} input" do
      assert_raise ArgumentError, ~r/requires a %URI\{\}/, fn ->
        Ezagent.URI.canonical!("entity://system/user/admin")
      end
    end

    test "canonical?/1 is true for external (non-Ezagent) schemes built via URI.new!" do
      # The rule is structural (authority:nil), scheme-INDEPENDENT.
      assert Ezagent.URI.canonical?(URI.new!("http://example.com/cb"))
      refute Ezagent.URI.canonical?(URI.parse("http://example.com/cb"))
    end
  end

  describe "parse/1 — non-raising inbound wrapper (URI hardening 2026-05-30)" do
    test "parse/1 yields the SAME canonical struct as new!/1" do
      for s <- @ezagent_scheme_examples do
        assert {:ok, uri} = Ezagent.URI.parse(s)
        assert uri == Ezagent.URI.new!(s), "parse/1 diverged from new!/1 for #{s}"
        assert Ezagent.URI.canonical?(uri)
      end
    end

    test "parse/1 returns {:error, :missing_scheme} for a schemeless string" do
      assert {:error, :missing_scheme} = Ezagent.URI.parse("/no-scheme")
    end

    test "parse/1 returns {:error, {:unregistered_scheme, _}} for external/deleted schemes" do
      assert {:error, {:unregistered_scheme, "http"}} = Ezagent.URI.parse("http://example.com")
      # NOTE: literal `user://...` deleted scheme is the point.
      assert {:error, {:unregistered_scheme, "user"}} =
               Ezagent.URI.parse("user" <> "://system/admin")
    end

    test "parse/1 returns {:error, {:invalid_shape, _}} for a 2-segment entity URI" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      assert {:error, {:invalid_shape, msg}} = Ezagent.URI.parse("entity://system/" <> "admin")
      assert msg =~ "type and name segments"
    end

    test "parse/1 returns {:error, {:malformed, _}} for an unparseable string" do
      assert {:error, {:malformed, _}} = Ezagent.URI.parse("ht!tp://bad uri ::::")
    end

    test "per-tenant URIs REQUIRE a non-empty workspace host (reject `scheme:///type/name`)" do
      # Without this, an empty-host per-tenant URI passes the path-shape check and
      # later falls back to the `:any` workspace — a cross-tenant scope/authz hole.
      for s <- [
            "entity://" <> "/agent/x",
            "session://" <> "/default/main",
            "template://" <> "/agent/x",
            "resource://" <> "/uploads/x"
          ] do
        assert {:error, {:invalid_shape, msg}} = Ezagent.URI.parse(s),
               "expected reject for #{inspect(s)}"

        assert msg =~ "workspace host", "wrong message for #{inspect(s)}: #{inspect(msg)}"

        assert_raise ArgumentError, ~r/workspace host/, fn -> Ezagent.URI.new!(s) end
      end
    end

    test "parse/1 never raises on the inputs new!/1 would reject" do
      bad = ["/no-scheme", "http://x", "entity://system/" <> "solo", "garbage ::::"]

      for s <- bad do
        assert match?({:error, _}, Ezagent.URI.parse(s)), "parse/1 should tag-error on #{s}"
      end
    end
  end

  describe "round-trip + idempotency (URI hardening 2026-05-30)" do
    test "parse(to_string(new!(x))) == new!(x) for every scheme" do
      for s <- @ezagent_scheme_examples do
        canon = Ezagent.URI.new!(s)
        assert {:ok, round} = Ezagent.URI.parse(URI.to_string(canon))
        assert round == canon, "round-trip via parse diverged for #{s}"
      end
    end

    test "new!(to_string(new!(x))) == new!(x) — idempotent re-parse" do
      for s <- @ezagent_scheme_examples do
        once = Ezagent.URI.new!(s)
        twice = Ezagent.URI.new!(URI.to_string(once))
        assert once == twice, "new!/1 re-parse not idempotent for #{s}"
      end
    end

    test "?action= query is preserved through round-trip" do
      s = "session://team-alpha/template-x/main?action=session.send"
      canon = Ezagent.URI.new!(s)
      assert canon.query == "action=session.send"
      {:ok, round} = Ezagent.URI.parse(URI.to_string(canon))
      assert round.query == "action=session.send"
      assert {:ok, {:session, :send}} = Ezagent.URI.behavior_action(round)
    end
  end

  describe "Map/MapSet key parity (the actual silent bug — URI hardening 2026-05-30)" do
    test "canonical key built two different ways matches in a Map" do
      # Both halves go through the sanctioned chokepoint -> identical struct.
      stored_key = Ezagent.URI.new!("entity://team-alpha/user/alice")
      lookup_key = Ezagent.URI.new!("entity://team-alpha/user/alice")
      m = %{stored_key => :online}
      assert Map.get(m, lookup_key) == :online
    end

    test "a NON-canonical lookup key SILENTLY misses a canonical Map key (demonstrates the bug)" do
      canonical_key = Ezagent.URI.new!("entity://team-alpha/user/alice")
      legacy_lookup = noncanonical_uri("entity://team-alpha/user/alice")
      m = %{canonical_key => :online}

      # This is the EXACT silent failure the guard exists to prevent:
      # same logical address, nil result, no crash.
      assert Map.get(m, legacy_lookup) == nil
    end

    test "canonical!/1 turns that silent miss into a LOUD crash at the boundary" do
      legacy_lookup = noncanonical_uri("entity://team-alpha/user/alice")

      # A consumer that asserts canonical form on its inbound key gets a
      # crash (attributable) instead of a silent nil.
      assert_raise ArgumentError, ~r/non-canonical/, fn ->
        Ezagent.URI.canonical!(legacy_lookup)
      end
    end

    test "MapSet membership matches for canonical peers, misses for non-canonical" do
      canon = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      set = MapSet.new([canon])
      assert MapSet.member?(set, Ezagent.URI.new!("entity://team-alpha/agent/cc_demo"))
      refute MapSet.member?(set, noncanonical_uri("entity://team-alpha/agent/cc_demo"))
    end
  end

  describe "with_action/3 — canonical dispatch-target constructor (URI hardening 2026-05-30)" do
    test "appends ?action=behavior.action to a canonical instance" do
      base = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      target = Ezagent.URI.with_action(base, :session, :receive)
      assert URI.to_string(target) == "entity://team-alpha/agent/cc_demo?action=session.receive"
      assert Ezagent.URI.canonical?(target)
      assert {:ok, {:session, :receive}} = Ezagent.URI.behavior_action(target)
    end

    test "accepts string behavior/action as well as atoms" do
      base = Ezagent.URI.new!("session://system/default/main")
      target = Ezagent.URI.with_action(base, "session", "send")
      assert {:ok, {:session, :send}} = Ezagent.URI.behavior_action(target)
    end

    test "replaces any stale action already on the base" do
      base = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo?action=old.verb")
      target = Ezagent.URI.with_action(base, :session, :send)
      assert {:ok, {:session, :send}} = Ezagent.URI.behavior_action(target)
    end

    test "works for cross-cutting schemes (workspace://, system://)" do
      ws =
        Ezagent.URI.with_action(Ezagent.URI.new!("workspace://team-alpha"), :routing, :add_rule)

      assert URI.to_string(ws) == "workspace://team-alpha?action=routing.add_rule"

      sys = Ezagent.URI.with_action(Ezagent.URI.new!("system://routing/default"), :routing, :add)
      assert URI.to_string(sys) == "system://routing/default?action=routing.add"
    end

    test "RAISES when the base is a non-canonical %URI{}" do
      legacy = noncanonical_uri("entity://team-alpha/agent/cc_demo")

      assert_raise ArgumentError, ~r/non-canonical/, fn ->
        Ezagent.URI.with_action(legacy, :session, :send)
      end
    end
  end

  describe "typed builders — semantic URI construction" do
    test "constructs per-tenant URIs from workspace/type/name arguments" do
      assert URI.to_string(Ezagent.URI.entity("team-alpha", :agent, "cc_demo")) ==
               "entity://team-alpha/agent/cc_demo"

      assert URI.to_string(Ezagent.URI.entity("system", :user, "admin")) ==
               "entity://system/user/admin"

      assert URI.to_string(Ezagent.URI.session("team-alpha", "code-review", "main")) ==
               "session://team-alpha/code-review/main"

      assert URI.to_string(Ezagent.URI.template("system", :agent, "cc-orchestrator")) ==
               "template://system/agent/cc-orchestrator"

      assert URI.to_string(Ezagent.URI.resource("team-alpha", :uploads, "file-abc")) ==
               "resource://team-alpha/uploads/file-abc"
    end

    test "constructs cross-cutting URIs" do
      assert URI.to_string(Ezagent.URI.workspace("team-alpha")) == "workspace://team-alpha"
      assert URI.to_string(Ezagent.URI.system(:routing, "default")) == "system://routing/default"
      assert URI.to_string(Ezagent.URI.system_principal(:bootstrap)) == "system://bootstrap"
    end

    test "rejects empty or slash-bearing segments" do
      assert_raise ArgumentError, ~r/URI segment must not be empty/, fn ->
        Ezagent.URI.entity("", :agent, "demo")
      end

      assert_raise ArgumentError, ~r/URI segment must not contain \//, fn ->
        Ezagent.URI.session("team-alpha", "code/review", "main")
      end
    end
  end

  describe "workspace_of/1 — centralized workspace accessor" do
    test "extracts workspaces for per-tenant schemes" do
      assert Ezagent.URI.workspace_of(Ezagent.URI.entity("team-alpha", :agent, "cc_demo")) ==
               Ezagent.URI.workspace("team-alpha")

      assert Ezagent.URI.workspace_of(Ezagent.URI.session("system", "default", "main")) ==
               Ezagent.URI.workspace("system")

      assert Ezagent.URI.workspace_of(Ezagent.URI.template("system", :agent, "cc-orchestrator")) ==
               Ezagent.URI.workspace("system")

      assert Ezagent.URI.workspace_of(Ezagent.URI.resource("team-alpha", :uploads, "file-abc")) ==
               Ezagent.URI.workspace("team-alpha")
    end

    test "returns the workspace URI itself for workspace:// and :any for system://" do
      workspace = Ezagent.URI.workspace("team-alpha")

      assert Ezagent.URI.workspace_of(workspace) == workspace
      assert Ezagent.URI.workspace_of(Ezagent.URI.system(:routing, "default")) == :any
    end

    test "extracts workspace names without external host/path matches" do
      assert {:ok, "team-alpha"} =
               Ezagent.URI.workspace_name(Ezagent.URI.entity("team-alpha", :agent, "cc_demo"))

      assert "team-alpha" =
               Ezagent.URI.workspace_name!(Ezagent.URI.session("team-alpha", "default", "main"))
    end
  end

  describe "type!/1 and name!/1 — centralized segment accessors" do
    test "extracts type and name for per-tenant schemes" do
      agent = Ezagent.URI.entity("team-alpha", :agent, "cc_demo")
      session = Ezagent.URI.session("team-alpha", "default", "main")

      assert Ezagent.URI.type!(agent) == "agent"
      assert Ezagent.URI.name!(agent) == "cc_demo"
      assert Ezagent.URI.type!(session) == "default"
      assert Ezagent.URI.name!(session) == "main"
    end

    test "extracts name for workspace:// and type/name for system://" do
      assert Ezagent.URI.name!(Ezagent.URI.workspace("team-alpha")) == "team-alpha"
      assert Ezagent.URI.type!(Ezagent.URI.system(:routing, "default")) == "routing"
      assert Ezagent.URI.name!(Ezagent.URI.system(:routing, "default")) == "default"
    end

    test "extracts names from unified path strings for parser consolidation" do
      assert Ezagent.URI.workspace_name_from_path("agent/cc_demo") == :error
      assert Ezagent.URI.workspace_name_from_path("/agent/cc_demo") == :error
      assert Ezagent.URI.workspace_name_from_path("legacy-name") == :error
      assert Ezagent.URI.name_from_path("agent/cc_demo") == {:ok, "cc_demo"}
      assert Ezagent.URI.name_from_path("/agent/cc_demo") == {:ok, "cc_demo"}
      assert Ezagent.URI.name_from_path("legacy-name") == {:ok, "legacy-name"}
      assert Ezagent.URI.name_from_path("") == :error
      assert Ezagent.URI.path_segments("type/workspace/name") == ["type", "workspace", "name"]
    end

    test "matches scheme/type/name predicates without exposing URI positions" do
      agent = Ezagent.URI.entity("team-alpha", :agent, "cc_demo")
      workspace = Ezagent.URI.workspace("team-alpha")
      system = Ezagent.URI.system(:routing, "default")

      assert Ezagent.URI.scheme?(agent, :entity)
      assert Ezagent.URI.type?(agent, :agent)
      refute Ezagent.URI.type?(agent, :user)
      assert Ezagent.URI.name?(agent, "cc_demo")

      assert Ezagent.URI.scheme?(workspace, :workspace)
      assert Ezagent.URI.name?(workspace, "team-alpha")
      refute Ezagent.URI.type?(workspace, :workspace)

      assert Ezagent.URI.scheme?(system, :system)
      assert Ezagent.URI.type?(system, :routing)
      assert Ezagent.URI.name?(system, :default)
    end
  end

  describe "parse!/1" do
    test "parses 3-segment entity:// URI (SPEC v3 §3.2)" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      assert uri.scheme == "entity"
      assert uri.host == "system"
      assert uri.path == "/user/admin"
    end

    test "parses URI with action query (SPEC v2 §5.2, PR #148)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo-builder?action=session.receive")
      assert uri.scheme == "entity"
      assert uri.host == "team-alpha"
      assert uri.path == "/agent/cc_demo-builder"
      assert uri.query == "action=session.receive"
    end

    test "parses cross-workspace entity URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      assert uri.scheme == "entity"
      assert uri.host == "team-alpha"
      assert uri.path == "/agent/cc_demo"
    end

    test "parses 3-segment session:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.new!("session://system/default/main")
      assert uri.scheme == "session"
      assert uri.host == "system"
      assert uri.path == "/default/main"
    end

    test "parses 3-segment template:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.new!("template://system/agent/cc-orchestrator")
      assert uri.scheme == "template"
      assert uri.host == "system"
      assert uri.path == "/agent/cc-orchestrator"
    end

    test "parses 3-segment resource:// URI (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.new!("resource://team-alpha/uploads/file-abc")
      assert uri.scheme == "resource"
      assert uri.host == "team-alpha"
      assert uri.path == "/uploads/file-abc"
    end

    test "rejects 2-segment session:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      legacy = "session://system/" <> "main"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 2-segment template:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      legacy = "template://system/" <> "cc-orch"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 2-segment resource:// URI (SPEC v3 §3.6 PR-7)" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      legacy = "resource://team-alpha/" <> "abc"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "raises on missing scheme" do
      assert_raise ArgumentError, ~r/missing scheme/, fn ->
        Ezagent.URI.new!("/no-scheme")
      end
    end

    test "raises on unknown scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        Ezagent.URI.new!("http://example.com")
      end
    end

    test "rejects deleted user:// scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        # NOTE: literal `user://default/admin` — the deleted scheme is the point.
        Ezagent.URI.new!("user" <> "://default/admin")
      end
    end

    test "rejects deleted agent:// scheme" do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        # NOTE: literal `agent://cc/demo` — the deleted scheme is the point.
        Ezagent.URI.new!("agent" <> "://cc/demo")
      end
    end

    test "rejects 2-segment entity URI (SPEC v3 §3.2)" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      legacy = "entity://system/" <> "admin"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 2-segment entity agent URI (SPEC v3 §3.2)" do
      # NOTE: literal workspace-first 2-seg form — rejected because the type axis is missing.
      legacy = "entity://team-alpha/" <> "cc_demo"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 4+ segment entity URI (sub-resource reserved)" do
      assert_raise ArgumentError, ~r/sub-resource positions are reserved/, fn ->
        Ezagent.URI.new!("entity://system/user/admin/extra")
      end
    end
  end

  describe "instance/1 — entity:// 3-segment authority (SPEC v3)" do
    test "entity:// strips query (SPEC v2 §5.2 — action lives in query)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=py.receive")
      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "entity"
      assert inst.host == "team-alpha"
      assert inst.path == "/agent/py_default"
      assert inst.query == nil
      assert URI.to_string(inst) == "entity://team-alpha/agent/py_default"
    end

    test "entity:// already-instance form is unchanged" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo-builder")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "entity://system/user/admin is unchanged" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "entity:// agent flavor in name prefix is opaque to parser" do
      # PR #141 SPEC v2 §5.14: <flavor>_<name> is one opaque name string.
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo-builder?action=session.receive")
      inst = Ezagent.URI.instance(uri)
      assert URI.to_string(inst) == "entity://team-alpha/agent/cc_demo-builder"
    end
  end

  describe "instance/1 — unified 3-seg schemes (SPEC v3 §3.6 PR-7)" do
    test "session:// strips query and keeps full 3-segment path" do
      uri = Ezagent.URI.new!("session://system/default/main?action=session.send")
      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "session"
      assert inst.host == "system"
      assert inst.path == "/default/main"
      assert inst.query == nil
      assert URI.to_string(inst) == "session://system/default/main"
    end

    test "template:// strips query and keeps full 3-segment path" do
      uri =
        Ezagent.URI.new!("template://system/agent/cc-orchestrator?action=identity.list_caps")

      inst = Ezagent.URI.instance(uri)
      assert inst.scheme == "template"
      assert inst.host == "system"
      assert inst.path == "/agent/cc-orchestrator"
      assert inst.query == nil
    end

    test "resource:// strips query and keeps full 3-segment path" do
      uri = Ezagent.URI.new!("resource://system/uploads/file-abc")
      assert Ezagent.URI.instance(uri) == uri
    end

    test "instance of workspace:// is unchanged (1-seg root scheme)" do
      uri = Ezagent.URI.new!("workspace://team-alpha")
      assert Ezagent.URI.instance(uri) == uri
    end
  end

  describe "entity_workspace_uri/1 (SPEC v3 §3.3)" do
    test "extracts workspace URI from default-workspace user entity" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/allen")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    test "extracts workspace URI from cross-workspace agent entity" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    # Phase 9 PR-8 (SPEC v3 §13): admin lives in workspace://system.
    test "extracts workspace://system URI from admin entity" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://system")
    end

    test "extracts workspace URI from entity URI with query string" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/allen?action=identity.list_caps")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    # V1 fix (Allen Feishu 2026-05-21) — was raising MatchError on
    # 2-segment input via the `[a, b] = String.split(...)` clause.
    # Now raises ArgumentError with a clear, actionable message
    # (defense in depth; LiveAuth's strict parse_entity_uri/1 is the
    # structural prevention).
    test "raises ArgumentError on legacy 2-segment URI (stale cookie regression)" do
      # Hand-construct the legacy shape — `parse!/1` correctly
      # rejects it at parse time, so we bypass to exercise the
      # defense-in-depth path inside entity_workspace_uri/1.
      legacy = %URI{scheme: "entity", host: "system", path: "/admin"}

      assert_raise ArgumentError, ~r/requires a 3-segment URI/, fn ->
        Ezagent.URI.entity_workspace_uri(legacy)
      end
    end

    test "raises ArgumentError mentions sign-in hint for stale cookies" do
      legacy = %URI{scheme: "entity", host: "team-alpha", path: "/cc_demo"}

      assert_raise ArgumentError, ~r/stale session cookie/, fn ->
        Ezagent.URI.entity_workspace_uri(legacy)
      end
    end

    test "raises ArgumentError on non-entity URI struct" do
      not_entity = Ezagent.URI.new!("session://system/default/main")

      assert_raise ArgumentError, ~r/requires %URI\{scheme: "entity"/, fn ->
        Ezagent.URI.entity_workspace_uri(not_entity)
      end
    end

    test "raises ArgumentError on non-URI input (e.g. plain string)" do
      assert_raise ArgumentError, ~r/requires %URI/, fn ->
        Ezagent.URI.entity_workspace_uri("entity://team-alpha/user/admin")
      end
    end

    test "raises ArgumentError on path-less entity URI" do
      pathless = %URI{scheme: "entity", host: "system", path: nil}

      assert_raise ArgumentError, ~r/requires a 3-segment URI/, fn ->
        Ezagent.URI.entity_workspace_uri(pathless)
      end
    end
  end

  describe "subresource/1" do
    test "entity:// without sub-resource returns empty string" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo-builder")
      assert Ezagent.URI.subresource(uri) == ""
    end

    test "entity:// with just /<type>/<name> → empty string" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      assert Ezagent.URI.subresource(uri) == ""
    end

    test "URI with no path → empty string" do
      uri = Ezagent.URI.new!("workspace://team-alpha")
      assert Ezagent.URI.subresource(uri) == ""
    end
  end

  describe "behavior_action/1 — query-string action parser (SPEC v2 §5.2, PR #148)" do
    test "extracts {behavior_atom, action_atom} from entity:// ?action=" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=py.receive")
      assert {:ok, {:py, :receive}} = Ezagent.URI.behavior_action(uri)
    end

    test "extracts from 3-seg session:// scheme (SPEC v3 §3.6 PR-7)" do
      uri = Ezagent.URI.new!("session://system/default/main?action=session.send")
      assert {:ok, {:session, :send}} = Ezagent.URI.behavior_action(uri)
    end

    test "extracts when behavior or action contains underscores" do
      uri = Ezagent.URI.new!("workspace://team-alpha/main?action=routing.add_rule")
      assert {:ok, {:routing, :add_rule}} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action for URI without query" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action when query lacks action key" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?foo=bar")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :missing_action for empty action value" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=")
      assert {:error, :missing_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :malformed_action when action lacks a dot" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=justone")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)
    end

    test "returns :malformed_action for empty behavior or action half" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=.say")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)

      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_default?action=py.")
      assert {:error, :malformed_action} = Ezagent.URI.behavior_action(uri)
    end
  end

  defp noncanonical_uri(s) when is_binary(s) do
    uri = Ezagent.URI.new!(s)
    %{uri | authority: uri.host}
  end
end
