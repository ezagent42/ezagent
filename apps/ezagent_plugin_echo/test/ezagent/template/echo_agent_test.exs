defmodule Ezagent.PluginEcho.Template.EchoAgentTest do
  @moduledoc """
  Tests for the `echo.agent` Template Class — Domain.Pty SPEC v1
  §10 row 3 + §11 item 6 (deferred PR-D sub-task, now in scope per
  Allen Feishu 2026-05-22).

  Mirrors the structure of `Ezagent.PluginCc.Template.CcAgentTest`:

  - `template_name/0` returns the stable id
  - `validate/1` accepts well-formed templates with/without `with_pty`
  - `validate/1` enforces `cwd` ONLY when `with_pty: true`
  - `instantiate/3` without `with_pty` spawns just the Agent Kind
  - `instantiate/3` with `with_pty: true` ALSO starts a PtyServer
    (verified via `Ezagent.Domain.Pty.alive?/1`)
  - `instantiate/3` is idempotent — re-running on an alive
    Kind + PTY does not duplicate
  - Template Class is registered at boot

  `instantiate/3` touches `Ezagent.SpawnRegistry.spawn/1` which goes
  through the chat domain's `entity://` spawn fn → snapshot
  persistence path → DB writes. This requires sandbox checkout so we
  manually plumb it in `setup` (echo plugin doesn't `use
  EzagentCore.DataCase` because that module lives in another app's
  test/support — and echo's mix.exs deliberately doesn't pull it in).
  """
  use ExUnit.Case, async: false

  alias Ezagent.PluginEcho.Template.EchoAgent

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "template_name/0" do
    test "returns 'echo.agent'" do
      assert EchoAgent.template_name() == "echo.agent"
    end
  end

  describe "validate/1" do
    test "accepts a well-formed template without with_pty (default)" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_no-pty"
               })
    end

    test "accepts a well-formed template with `with_pty: false`" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_off",
                 "with_pty" => false,
                 # cwd allowed but ignored when with_pty: false
                 "cwd" => ""
               })
    end

    test "accepts a well-formed template with `with_pty: true` + cwd" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_on",
                 "with_pty" => true,
                 "cwd" => "/tmp"
               })
    end

    test "rejects `with_pty: true` without cwd" do
      assert {:error, :cwd_required_when_with_pty} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_x",
                 "with_pty" => true
               })
    end

    test "rejects `with_pty: true` with blank cwd" do
      assert {:error, :cwd_required_when_with_pty} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_x",
                 "with_pty" => true,
                 "cwd" => ""
               })
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               EchoAgent.validate(%{"agent_uri" => "entity://team-alpha/agent/echo_x"})
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.agent"}} =
               EchoAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/echo_x"
               })
    end

    test "rejects missing agent_uri" do
      assert {:error, :missing_agent_uri} =
               EchoAgent.validate(%{"class" => "echo.agent"})
    end

    test "ignores legacy name prefix when validating stored flavor" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_demo"
               })
    end

    test "accepts entity://agent/<name> without flavor prefix" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/agent/just-a-name"
               })
    end

    test "rejects entity://user/... (wrong entity type — must be agent)" do
      assert {:error, {:invalid_agent_uri, _, _}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://team-alpha/user/x"
               })
    end

    test "rejects non-entity scheme" do
      assert {:error, {:invalid_agent_uri, _, "agent URI must be an entity agent URI"}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "session://system/default/main"
               })
    end
  end

  describe "instantiate/3 — without with_pty" do
    test "spawns the Agent Kind alone (no PtyServer)" do
      agent_uri_str =
        "entity://team-alpha/agent/echo_test-no-pty-#{System.unique_integer([:positive])}"

      # Build via the canonical chokepoint so the pinned struct matches
      # what `instantiate/3` returns. Post-SPEC 2026-05-27 URI
      # canonicalization (#431/#438) the product threads URIs through
      # `Ezagent.URI.new!/1`, whose canonical `%URI{}` does NOT carry the
      # `authority` field that `URI.parse/1` populates — so a
      # `URI.parse`-built pin no longer `==` the returned URI.
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — `instantiate/3` returns the 3-element
      # `{:ok, uris, %{fresh?: _}}` form; a first spawn is `fresh?: true`.
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      # Agent Kind alive
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after echo.agent.instantiate without with_pty"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      # PtyServer NOT started
      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "PtyServer must NOT be started when with_pty is false/absent"
    end
  end

  describe "instantiate/3 — with with_pty: true" do
    test "spawns BOTH the Agent Kind AND a PtyServer (Domain.Pty SPEC §4 cross-flavor opt-in)" do
      agent_uri_str =
        "entity://team-alpha/agent/echo_test-pty-#{System.unique_integer([:positive])}"

      # Build via the canonical chokepoint so the pinned struct matches
      # what `instantiate/3` returns. Post-SPEC 2026-05-27 URI
      # canonicalization (#431/#438) the product threads URIs through
      # `Ezagent.URI.new!/1`, whose canonical `%URI{}` does NOT carry the
      # `authority` field that `URI.parse/1` populates — so a
      # `URI.parse`-built pin no longer `==` the returned URI.
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str,
        "with_pty" => true,
        "cwd" => System.tmp_dir!()
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — 3-element return; a first spawn is fresh.
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      # Both halves alive — the cross-flavor invariant.
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after echo.agent.instantiate with_pty: true"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert Ezagent.Domain.Pty.alive?(agent_uri),
             "PtyServer must be alive after echo.agent.instantiate with_pty: true"

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri)
      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "is idempotent — second call returns same URI without spawning a second PtyServer" do
      agent_uri_str =
        "entity://team-alpha/agent/echo_idem-#{System.unique_integer([:positive])}"

      # Build via the canonical chokepoint so the pinned struct matches
      # what `instantiate/3` returns. Post-SPEC 2026-05-27 URI
      # canonicalization (#431/#438) the product threads URIs through
      # `Ezagent.URI.new!/1`, whose canonical `%URI{}` does NOT carry the
      # `authority` field that `URI.parse/1` populates — so a
      # `URI.parse`-built pin no longer `==` the returned URI.
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str,
        "with_pty" => true,
        "cwd" => System.tmp_dir!()
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — first spawn is fresh, the idempotent
      # re-call adopts the already-live worker (`fresh?: false`).
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      pids_before = list_pty_pids_for(agent_uri_str)
      assert length(pids_before) == 1

      assert {:ok, [^agent_uri], %{fresh?: false}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      pids_after = list_pty_pids_for(agent_uri_str)
      assert pids_after == pids_before
    end

    # codex round-8 HIGH-1 — when the Agent Kind already exists (a
    # worker THIS instantiate did NOT create — e.g. spawned directly by
    # a concurrent path), `instantiate/3` with `with_pty: true` must
    # return `fresh?: false` WITHOUT starting a PTY sidecar. Mirrors
    # `Ezagent.PluginCc.Template.CcAgentTest`'s no-sidecar test.
    test "an already-started Agent Kind returns fresh?: false and starts NO PtyServer" do
      agent_uri_str =
        "entity://team-alpha/agent/echo_already-#{System.unique_integer([:positive])}"

      # Build via the canonical chokepoint so the pinned struct matches
      # what `instantiate/3` returns. Post-SPEC 2026-05-27 URI
      # canonicalization (#431/#438) the product threads URIs through
      # `Ezagent.URI.new!/1`, whose canonical `%URI{}` does NOT carry the
      # `authority` field that `URI.parse/1` populates — so a
      # `URI.parse`-built pin no longer `==` the returned URI.
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      # Bring up ONLY the Echo Kind — directly, NOT via the template or
      # URI-derived flavor dispatch. Kind alive, no PtyServer: the
      # "worker this call did not create" state.
      assert {:ok, _pid} =
               Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
                 uri: agent_uri,
                 behaviors: Ezagent.Entity.Agent.echo_behaviors()
               })

      assert {:ok, _} = Ezagent.KindRegistry.lookup(agent_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "precondition: no PtyServer before instantiate"

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str,
        "with_pty" => true,
        "cwd" => System.tmp_dir!()
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # Kind alive but PTY absent → idempotency short-circuit does not
      # fire → `ensure_agent_kind` reports `:already_started` → the
      # fresh-check gates the sidecar: `fresh?: false`, NO PTY.
      assert {:ok, [^agent_uri], %{fresh?: false}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "a rejected adoption must NOT start a PTY sidecar (codex round-8 HIGH-1)"

      assert list_pty_pids_for(agent_uri_str) == [],
             "no PtyServer process may exist for an already-started Agent Kind"
    end
  end

  # A4 — echo template path must thread `behaviors: echo_behaviors()` at spawn.
  # Without the fix, `ensure_agent_kind/1` used `SpawnRegistry.spawn_detailed/1`
  # (no args), causing `Entity.Agent` to boot with `nil_capture_behavior_set/0`
  # (base behaviors only, NO Echo). A `:say` dispatch would then fail with
  # `:unknown_action` — the agent has Identity but no Echo behavior.
  describe "instantiate/3 — echo behavior presence (A4)" do
    test ":say dispatch succeeds on template-spawned echo agent (proves Echo behavior is in instance set)" do
      agent_uri_str =
        "entity://team-alpha/agent/echo_a4-#{System.unique_integer([:positive])}"

      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      # Wait for the Kind to become ready (snapshot load / create completes).
      wait_until_ready(agent_uri)

      target = Ezagent.URI.new!("#{agent_uri_str}?action=echo.say")

      # A `:say` dispatch PROVES Echo behavior is in the instance set.
      # Without `behaviors: echo_behaviors()` threaded at spawn, the agent
      # boots with base behaviors only → `:say` would return `{:error,
      # {:unknown_action, _}}`. The fix makes it return `{:ok, %{echo: ...}}`.
      assert {:ok, %{echo: "hello"}} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 target: target,
                 mode: :call,
                 args: %{msg: "hello"},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                   reply: {:caller_inbox, self()}
                 }
               })
    end
  end

  describe "registry integration" do
    test "Template Class is registered at boot" do
      assert {:ok, Ezagent.PluginEcho.Template.EchoAgent} =
               Ezagent.TemplateRegistry.lookup("echo.agent")
    end
  end

  describe "form_fields/0" do
    # Phase 5 PR 2 SPEC_REVIEW R6 froze the form field type allowlist
    # at `:text | :path | :uri | :select`. Echo's PR-191 `:boolean`
    # field violated that allowlist (caught by Ezagent.UI.FormTest) AND
    # rendered as a plain text input (the LV switch had no `:boolean`
    # arm) AND submitted "true" strings the validate path silently
    # downgraded to no-PTY. The `:select` rewrite stays inside the
    # frozen contract.
    test "every field type stays inside the Form-callback frozen allowlist" do
      allowed = [:text, :path, :uri, :select]

      for field <- EchoAgent.form_fields() do
        assert field.type in allowed,
               "echo.agent field #{inspect(field.name)} has out-of-allowlist type #{inspect(field.type)}"
      end
    end

    test "declares agent_uri (uri, required), with_pty (select), cwd (path)" do
      fields = EchoAgent.form_fields()

      agent_uri_field = Enum.find(fields, fn f -> f.name == "agent_uri" end)
      assert agent_uri_field.type == :uri
      assert agent_uri_field.required == true

      with_pty_field = Enum.find(fields, fn f -> f.name == "with_pty" end)
      assert with_pty_field.type == :select
      assert with_pty_field.options == ["false", "true"]

      assert Enum.find(fields, fn f -> f.name == "cwd" end).type == :path
    end
  end

  describe "form_to_args/1" do
    # Production path: the LV add-template form submits `with_pty` as
    # a `"true"` / `"false"` STRING (HTML <select> values are
    # strings). `validate/1` pattern-matches the atom-boolean
    # `with_pty: true`, so without an explicit coercion the operator's
    # "with PTY" choice was silently dropped pre-fix — the agent
    # would spawn without a PTY sidecar with NO error surfaced.
    test "coerces with_pty=\"true\" string to atom true" do
      out =
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_my-bot",
          "with_pty" => "true",
          "cwd" => "/tmp/echo-sandbox"
        })

      assert out["with_pty"] == true
      assert out["class"] == "echo.agent"
      assert out["agent_uri"] == "entity://team-alpha/agent/echo_my-bot"
      assert out["cwd"] == "/tmp/echo-sandbox"
    end

    test "coerces with_pty=\"false\" string to atom false" do
      out =
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_no-pty",
          "with_pty" => "false"
        })

      assert out["with_pty"] == false
      assert out["class"] == "echo.agent"
    end

    test "output passes validate/1 round-trip (with_pty true + cwd)" do
      out =
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_roundtrip",
          "with_pty" => "true",
          "cwd" => "/tmp"
        })

      assert :ok = EchoAgent.validate(out)
    end

    test "output passes validate/1 round-trip (with_pty false, no cwd)" do
      out =
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_roundtrip-off",
          "with_pty" => "false"
        })

      assert :ok = EchoAgent.validate(out)
    end

    # codex r1 MEDIUM (2026-05-26) — fail fast on with_pty drift.
    # Anything other than "true"/"false" used to silently fall through
    # to validate/1's catch-all and downgrade to no-PTY, dropping the
    # operator's intent on the floor.
    test "raises on with_pty value other than \"true\"/\"false\"" do
      assert_raise ArgumentError, ~r/with_pty must be/, fn ->
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_drift",
          "with_pty" => "yes"
        })
      end

      assert_raise ArgumentError, ~r/with_pty must be/, fn ->
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_drift",
          "with_pty" => "tru"
        })
      end
    end

    # codex r1 LOW (2026-05-26) — the default form_to_args path in
    # workspace_detail_live drops "tmpl_name" before constructing
    # template_data; the override path must match (same shape, no
    # redundant identity field stored inside the template map).
    test "drops tmpl_name from output (matches default-path Map.drop in workspace_detail_live)" do
      out =
        EchoAgent.form_to_args(%{
          "tmpl_name" => "echo-test",
          "agent_uri" => "entity://team-alpha/agent/echo_xyz",
          "with_pty" => "false"
        })

      refute Map.has_key?(out, "tmpl_name")
      assert out["agent_uri"] == "entity://team-alpha/agent/echo_xyz"
      assert out["class"] == "echo.agent"
    end

    test "with_pty absent → output omits with_pty (validate defaults to no-PTY)" do
      out =
        EchoAgent.form_to_args(%{
          "agent_uri" => "entity://team-alpha/agent/echo_no-field"
        })

      refute Map.has_key?(out, "with_pty")
      assert :ok = EchoAgent.validate(out)
    end
  end

  defp list_pty_pids_for(agent_uri_str) do
    Ezagent.Domain.Pty.Server.list_agents()
    |> Enum.filter(fn a -> URI.to_string(a.agent_uri) == agent_uri_str end)
    |> Enum.map(& &1.pid)
  end

  # A4 helper — poll ReadyGate until the Kind signals :ready (snapshot
  # load / create completes). Mirrors `echo_cold_load_test.exs`.
  defp wait_until_ready(uri, attempts \\ 100)
  defp wait_until_ready(_uri, 0), do: flunk("wait_until_ready: Kind never reached :ready")

  defp wait_until_ready(uri, attempts) do
    if Ezagent.ReadyGate.status(uri) == :ready do
      :ok
    else
      Process.sleep(10)
      wait_until_ready(uri, attempts - 1)
    end
  end
end
