defmodule EzagentWeb.LiveAuthTest do
  @moduledoc """
  V1 fix (Allen Feishu 2026-05-21) — `LiveAuth.parse_entity_uri/1`
  delegates to `Ezagent.URI.new!/1` (the SPEC v3 canonical parser)
  so the write side (`EzagentWeb.SessionPrincipal.canonicalize/2` —
  3-segment URIs) and the read side (LiveAuth) cannot diverge.

  Regression context: pre-Phase-9 cookies that held a legacy
  2-segment entity URI (e.g. `entity://user/` + `admin`) previously
  parsed `{:ok, _}` here and were forwarded into
  `Ezagent.URI.entity_workspace_uri/1`, which pattern-matches a
  3-segment URI → `MatchError` → 500 at GET /sessions. Memory
  `feedback_register_lookup_key_parity`.

  task #180 Change 3 — `on_mount(:require_entity, ...)` now EVICTS a user
  disabled after login (active-session eviction). That recheck reads
  the `users` table, so this suite runs under `DataCase` (DB sandbox) and
  seeds the active user URIs it asserts `{:cont}` for.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentWeb.LiveAuth
  alias Ezagent.Users

  # Seed the ACTIVE user URIs the `{:cont}` parity tests below assert on, so
  # the Change 3 recheck (`Users.disabled?/1`, fail-closed on unknown) lets
  # them through. Agent URIs and the `:halt` parse-rejection cases never reach
  # the recheck.
  setup do
    for uri <- [
          "entity://team-alpha/user/admin",
          "entity://team-alpha/user/alice",
          "entity://system/user/linyilun"
        ] do
      {:ok, _} = Users.create(uri, "pw", [])
    end

    :ok
  end

  # `parse_entity_uri/1` is private — we exercise it via the public
  # `on_mount(:require_entity, ...)` entry point. A stale 2-segment
  # cookie therefore manifests as a `:halt` + redirect tuple (not a
  # crash), which is the production-visible behavior we care about.

  describe "on_mount(:require_entity, ...) — strict URI parity (V1 fix)" do
    test "accepts canonical 3-segment entity://user URI" do
      socket = build_socket()

      assert {:cont, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "entity://team-alpha/user/admin"},
                 socket
               )

      assert %URI{scheme: "entity", host: "team-alpha", path: "/user/admin"} =
               socket.assigns.current_entity_uri
    end

    test "accepts canonical 3-segment entity://agent URI" do
      socket = build_socket()

      assert {:cont, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "entity://team-alpha/agent/cc_demo"},
                 socket
               )

      assert %URI{scheme: "entity", host: "team-alpha", path: "/agent/cc_demo"} =
               socket.assigns.current_entity_uri
    end

    test "REJECTS 2-segment user URI (stale pre-Phase-9 cookie regression)" do
      # The exact symptom Allen reported: a session cookie carrying a
      # legacy 2-segment entity URI reached LiveAuth and propagated
      # into entity_workspace_uri/1 → MatchError 500. After the V1
      # fix, parse!/1 raises ArgumentError → :error → halt+redirect
      # to /login WITHOUT touching entity_workspace_uri.
      socket = build_socket()
      # NOTE: split-literal is the convention so the
      # `entities_have_workspace_test.exs` grep gate skips this
      # intentionally-2-segment regression case.
      stale = "entity://user/" <> "admin"

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => stale},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
      assert socket.assigns.flash["info"] =~ "Your session expired"
    end

    test "REJECTS 2-segment agent URI (stale agent cookie)" do
      socket = build_socket()
      stale = "entity://agent/" <> "cc_demo"

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => stale},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS non-entity scheme (session://system/default/main)" do
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "session://system/default/main"},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS deleted scheme (user://default/admin)" do
      socket = build_socket()
      # NOTE: literal `user://` is the deleted-scheme regression point.
      stale = "user" <> "://default/admin"

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => stale},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS unknown host in entity scheme (entity://device/default/admin)" do
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "entity://device/default/admin"},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS empty string" do
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => ""},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS nil (no session)" do
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => nil},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS missing session key" do
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(:require_entity, %{}, %{}, socket)

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "REJECTS bare string (raw user input — defense in depth)" do
      # Same hole RequireEntity plug closes (see plugs/require_entity_test.exs).
      # LiveAuth must close it too so the WS reconnect path is symmetric.
      socket = build_socket()

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "admin"},
                 socket
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "stale cookie DOES NOT raise MatchError — surfaces as graceful redirect" do
      # The specific behavior that broke production: LiveAuth must
      # NEVER raise on a parseable-but-non-canonical cookie value.
      # Worst case is a halt+redirect, never a 500.
      socket = build_socket()
      stale = "entity://user/" <> "admin"

      # If this raises (MatchError or otherwise), the test fails.
      result =
        LiveAuth.on_mount(
          :require_entity,
          %{},
          %{"current_entity_uri" => stale},
          socket
        )

      assert match?({:halt, _}, result)
    end
  end

  describe "on_mount(:require_entity, ...) — workspace_name assign (Bug 3)" do
    # Allen 2026-05-26 — the IdeShell top-left `ezagent / <name>`
    # dropdown trigger reads `@workspace_name`. Before this fix it
    # was only computed by `admin_live`, and from the wrong source
    # (the session URI's bound workspace, NOT the user's
    # current_workspace_uri slot). After a successful
    # `POST /workspaces/switch` the cookie's workspace slot
    # updated but the label still showed the old value, so the
    # switch LOOKED broken. Now LiveAuth sets `:workspace_name`
    # centrally from `:current_workspace_uri`, which is the SoT.
    test "assigns :workspace_name from :current_workspace_uri (explicit slot)" do
      socket = build_socket()

      assert {:cont, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{
                   "current_entity_uri" => "entity://team-alpha/user/alice",
                   "current_workspace_uri" => "workspace://team-alpha"
                 },
                 socket
               )

      assert socket.assigns.workspace_name == "team-alpha"
    end

    test "assigns :workspace_name from derived workspace (no explicit slot)" do
      socket = build_socket()

      assert {:cont, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => "entity://team-alpha/user/alice"},
                 socket
               )

      # Defensive fallback: derive from entity URI when the cookie
      # slot is missing (pre-PR-5 sessions).
      assert socket.assigns.workspace_name == "team-alpha"
    end

    test ":workspace_name follows a workspace switch (regression)" do
      # Simulates what `WorkspaceSwitchController.do_switch/3` does
      # for a system-member context swap: rewrites
      # `:current_workspace_uri` while keeping `:current_entity_uri`.
      # The LV's IdeShell trigger MUST reflect the new workspace.
      socket = build_socket()

      assert {:cont, socket_before} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{
                   "current_entity_uri" => "entity://system/user/linyilun",
                   "current_workspace_uri" => "workspace://system"
                 },
                 socket
               )

      assert socket_before.assigns.workspace_name == "system"

      # Now the controller rewrote the workspace slot. The next LV
      # mount sees the new value.
      assert {:cont, socket_after} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{
                   "current_entity_uri" => "entity://system/user/linyilun",
                   "current_workspace_uri" => "workspace://h2oslabs"
                 },
                 socket
               )

      assert socket_after.assigns.workspace_name == "h2oslabs",
             "label MUST follow the cookie's current_workspace_uri after a switch"
    end
  end

  describe "on_mount(:require_entity, ...) — active-session eviction (task #180 Change 3)" do
    test "evicts a user disabled AFTER login on the next LV mount" do
      uri = "entity://team-alpha/user/evict-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])

      # Active → mounts.
      assert {:cont, _} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => uri},
                 build_socket()
               )

      # Operator disables; next mount is bounced.
      {:ok, _} = Users.disable(uri, "entity://system/user/admin", "offboarded")

      assert {:halt, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => uri},
                 build_socket()
               )

      assert {:redirect, %{to: "/login"}} = socket.redirected
      assert socket.assigns.flash["info"] =~ "revoked"
    end

    test "an ACTIVE user still mounts (recheck is not a blanket denial)" do
      uri = "entity://team-alpha/user/active-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])

      assert {:cont, socket} =
               LiveAuth.on_mount(
                 :require_entity,
                 %{},
                 %{"current_entity_uri" => uri},
                 build_socket()
               )

      assert %URI{scheme: "entity"} = socket.assigns.current_entity_uri
    end
  end

  # Build a minimal `%Phoenix.LiveView.Socket{}` suitable for direct
  # `on_mount/4` invocation. The hook only reads/writes assigns +
  # `:redirected`, so we don't need a real LV transport.
  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end
end
