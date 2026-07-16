defmodule Mix.Tasks.Ezagent.ExternalMirrorTest do
  @moduledoc """
  Combined Mix-task suite for SPEC §9 PR-EM-5 — the four
  `mix ezagent.external_mirror.*` tasks. Tests cover:

  1. `list_adapters` — outputs the registered mock adapter
  2. `bind` happy path — caller with caps binds successfully
  3. `bind` with missing caps — exits 1 + error on stderr
  4. `unbind` happy path — removes the binding
  5. `list_bindings` — outputs both bindings on a session with 2

  All tests reuse the in-domain `MockPublishAdapter` /
  `MockPublishBinding` test-support modules (loaded via
  `test/support/`). The Mix tasks call the `Ezagent.ExternalMirror`
  facade directly — same dispatch path as the LV — so the cap
  checks, audit telemetry, and cross-workspace gates fire as in
  production.

  ## `Mix.raise/1` interception

  The CLI helper module exits on cap-miss / unknown-args / facade
  error via `Mix.raise/1` (which raises `Mix.Error` and exits with
  1 when run via `mix`). ExUnit catches `Mix.Error` cleanly via
  `assert_raise/3` + `ExUnit.CaptureIO.capture_io(:stderr, ...)`.
  Earlier drafts used `System.halt/1` which would terminate the
  whole VM under test; that approach was replaced (codex r1 fix
  2026-05-25).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Entity.{Session, User}

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    BindingRow,
    RootSupervisor
  }

  alias Ezagent.ExternalMirror.TestSupport.{
    MockPublishAdapter,
    MockPublishBinding
  }

  alias Ezagent.ExternalMirror, as: Facade

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

  setup do
    :ok = ensure_adapter_registered(MockPublishAdapter, MockPublishBinding)
    cleanup_workers()

    session_uri = unique_session_uri("pr5")
    owner_uri = unique_user_uri("pr5-owner")

    on_exit(fn ->
      cleanup_session(session_uri)
      cleanup_workers()
    end)

    {:ok, session_uri: session_uri, owner_uri: owner_uri}
  end

  # ===========================================================================
  # 1. list_adapters
  # ===========================================================================

  describe "Mix.Tasks.Ezagent.ExternalMirror.ListAdapters" do
    test "outputs the registered mock adapter" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListAdapters.run([])
        end)

      assert output =~ "mock_publish"
      assert output =~ "id"
      assert output =~ "display_name"
      # Plain table — three header cols.
      assert output =~ "description"
    end

    test "ignores --as / --metadata flags (no caps check on metadata reads)" do
      # No caps required → --as can be omitted entirely; passing it
      # must not cause an exit-1 cap denial.
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListAdapters.run([
            "--as",
            "entity://team-alpha/user/anyone"
          ])
        end)

      assert output =~ "mock_publish"
    end
  end

  # ===========================================================================
  # 2. bind happy path
  # ===========================================================================

  describe "Mix.Tasks.Ezagent.ExternalMirror.Bind" do
    test "owner with admin caps binds via the facade (slice + projection row)",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_id = "tgt-pr5-bind-happy"
      MockPublishBinding.register_observer(target_id, self())

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
            URI.to_string(session_uri),
            "mock_publish",
            target_id,
            "--as",
            URI.to_string(owner_uri)
          ])
        end)

      assert output =~ "ok"
      assert output =~ "binding_id="
      assert output =~ "mock_publish"
      assert output =~ target_id

      # Slice + DB projection assertions via the facade (admin ctx
      # bypasses workspace filter so we see the row).
      assert {:ok, [%{adapter_id: "mock_publish", target_id: ^target_id}]} =
               Facade.list_bindings(session_uri, owner_ctx(owner_uri))

      assert [%BindingRow{adapter_id: "mock_publish"}] = BindingRow.list_for_session(session_uri)
    end

    test "bind with --metadata key=val forwards the metadata as opts",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_id = "tgt-pr5-bind-meta"
      MockPublishBinding.register_observer(target_id, self())

      _ =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
            URI.to_string(session_uri),
            "mock_publish",
            target_id,
            "--as",
            URI.to_string(owner_uri),
            "--metadata",
            "silent_mode=true",
            "--metadata",
            "channel=alpha"
          ])
        end)

      # The opts land in the slice — facade.list_bindings exposes them.
      assert {:ok, [%{target_id: ^target_id, opts: opts}]} =
               Facade.list_bindings(session_uri, owner_ctx(owner_uri))

      assert opts["silent_mode"] == "true"
      assert opts["channel"] == "alpha"
    end
  end

  # ===========================================================================
  # 3. bind with missing caps — exits 1 + verbatim error to stderr
  # ===========================================================================

  describe "Mix.Tasks.Ezagent.ExternalMirror.Bind — cap denial" do
    test "caller without session :bind cap → Mix.Error :unauthorized + verbatim stderr",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Fresh user with NO caps at all → client-side `require_session_cap!`
      # short-circuits with :unauthorized BEFORE any dispatch.
      caller_uri = unique_user_uri("pr5-nocaps")
      :ok = spawn_user(caller_uri, MapSet.new())

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/:unauthorized/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
              URI.to_string(session_uri),
              "mock_publish",
              "tgt-pr5-cap-deny",
              "--as",
              URI.to_string(caller_uri)
            ])
          end
        end)

      # Mix.shell().error/1 writes to stderr — capture proves the
      # operator-facing line was emitted (per P18 verbatim).
      assert stderr_output =~ ":unauthorized"
      assert stderr_output =~ URI.to_string(caller_uri)

      # No row landed (the Mix.raise/1 short-circuits BEFORE dispatch).
      assert [] = BindingRow.list_for_session(session_uri)
    end

    test "facade returning :adapter_not_authorized is surfaced verbatim per P18",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Caller holds Cap 1 (`Behavior.ExternalMirror`) on the session
      # so the client-side check passes — BUT they don't hold the
      # per-adapter allow cap (Cap 2). The facade's `check_adapter_allow_cap`
      # returns `:adapter_not_authorized`; the CLI's `surface_error/1`
      # MUST print that atom verbatim per P18.
      caller_uri = unique_user_uri("pr5-cap1-only")

      cap1 = %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: session_uri,
        workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }

      signed_cap1 = Ezagent.Test.CapHelper.signed_cap!(session_uri, caller_uri, cap1)
      :ok = spawn_user(caller_uri, MapSet.new([signed_cap1]))

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/adapter_not_authorized/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
              URI.to_string(session_uri),
              "mock_publish",
              "tgt-pr5-cap2-deny",
              "--as",
              URI.to_string(caller_uri)
            ])
          end
        end)

      assert stderr_output =~ ":adapter_not_authorized"
      assert [] = BindingRow.list_for_session(session_uri)
    end
  end

  # ===========================================================================
  # 3b. codex r1 HIGH regressions — caller URI required (no silent admin fallback)
  # ===========================================================================

  describe "codex r1 HIGH — caller URI required for bind / unbind / list_bindings" do
    test "bind WITHOUT --as and WITHOUT EZAGENT_AS_USER → Mix.Error + stderr explains",
         %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/missing --as/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
              URI.to_string(session_uri),
              "mock_publish",
              "tgt-pr5-missing-as"
            ])
          end
        end)

      assert stderr_output =~ "--as"
      assert stderr_output =~ "EZAGENT_AS_USER"
      assert stderr_output =~ "NO silent admin fallback"
    end

    test "unbind without caller → Mix.Error", %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      _ =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/missing --as/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.Unbind.run([
              URI.to_string(session_uri),
              "mock_publish",
              "tgt"
            ])
          end
        end)
    end

    test "list_bindings without caller → Mix.Error", %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      _ =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/missing --as/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.ListBindings.run([URI.to_string(session_uri)])
          end
        end)
    end

    test "list_adapters WITHOUT --as is OK (unauthed metadata exception, SPEC §9 PR-EM-1)" do
      System.delete_env("EZAGENT_AS_USER")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListAdapters.run([])
        end)

      # No raise; the admin fallback inside parse_argv with
      # `caller_required: false` is the legitimate exception.
      assert output =~ "id"
    end
  end

  # ===========================================================================
  # 3b2. codex r2 MED regression — --help short-circuits caller resolution
  # ===========================================================================

  describe "codex r2 MED — --help short-circuits caller resolution" do
    test "bind --help without --as or EZAGENT_AS_USER → prints help (no Mix.raise)",
         %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      # Pre-r2-fix: parse_argv resolved caller BEFORE noticing --help,
      # so help text would raise `:missing --as`. Post-fix: help
      # short-circuits, print + return ok.
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
            URI.to_string(session_uri),
            "mock_publish",
            "tgt",
            "--help"
          ])
        end)

      # Help text mentions the module's purpose. No exception raised.
      assert output =~ "Bind" or output =~ "bind"
    end

    test "unbind --help without --as → prints help",
         %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Unbind.run([
            URI.to_string(session_uri),
            "mock_publish",
            "tgt",
            "--help"
          ])
        end)

      assert output =~ "Unbind" or output =~ "unbind"
    end

    test "list_bindings --help without --as → prints help",
         %{session_uri: session_uri} do
      System.delete_env("EZAGENT_AS_USER")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListBindings.run([
            URI.to_string(session_uri),
            "--help"
          ])
        end)

      assert output =~ "list_bindings" or output =~ "List"
    end
  end

  # ===========================================================================
  # 3b3. codex r2 LOW — list_adapters rejects stray positional args
  # ===========================================================================

  describe "codex r2 LOW — list_adapters rejects stray positional args" do
    test "list_adapters with extra arg → Mix.Error :unexpected positional args" do
      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/unexpected positional args/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.ListAdapters.run(["garbage"])
          end
        end)

      assert stderr_output =~ "garbage"
      assert stderr_output =~ "no positional args"
    end
  end

  # ===========================================================================
  # 3c. codex r1 MED-1 regression — unknown options rejected (no silent drop)
  # ===========================================================================

  describe "codex r1 MED-1 — unknown options rejected" do
    test "bind with --ass (typo) → Mix.Error, does NOT silently fall through to admin",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      stderr_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/unknown options/, fn ->
            Mix.Tasks.Ezagent.ExternalMirror.Bind.run([
              URI.to_string(session_uri),
              "mock_publish",
              "tgt-pr5-typo",
              "--ass",
              URI.to_string(owner_uri)
            ])
          end
        end)

      assert stderr_output =~ "unknown options"
      assert stderr_output =~ "ass"
    end
  end

  # ===========================================================================
  # 4. unbind happy path
  # ===========================================================================

  describe "Mix.Tasks.Ezagent.ExternalMirror.Unbind" do
    test "removes the binding from slice + projection",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_id = "tgt-pr5-unbind"
      MockPublishBinding.register_observer(target_id, self())

      {:ok, _} = Facade.bind(session_uri, "mock_publish", target_id, %{}, owner_ctx(owner_uri))

      # Sanity: bound.
      assert [%BindingRow{}] = BindingRow.list_for_session(session_uri)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Unbind.run([
            URI.to_string(session_uri),
            "mock_publish",
            target_id,
            "--as",
            URI.to_string(owner_uri)
          ])
        end)

      assert output =~ "ok"
      assert output =~ "unbound=true"

      # Slice + DB row gone.
      assert {:ok, []} = Facade.list_bindings(session_uri, owner_ctx(owner_uri))
      assert [] = BindingRow.list_for_session(session_uri)
    end

    test "idempotent: unbinding a non-existent binding → success no-op",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.Unbind.run([
            URI.to_string(session_uri),
            "mock_publish",
            "tgt-never-bound",
            "--as",
            URI.to_string(owner_uri)
          ])
        end)

      assert output =~ "ok"
      assert output =~ "unbound=false"
    end
  end

  # ===========================================================================
  # 5. list_bindings on session with 2 bindings — outputs both
  # ===========================================================================

  describe "Mix.Tasks.Ezagent.ExternalMirror.ListBindings" do
    test "outputs all bindings on a session with 2",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      target_a = "tgt-pr5-list-A"
      target_b = "tgt-pr5-list-B"

      MockPublishBinding.register_observer(target_a, self())
      MockPublishBinding.register_observer(target_b, self())

      {:ok, _} = Facade.bind(session_uri, "mock_publish", target_a, %{}, owner_ctx(owner_uri))
      {:ok, _} = Facade.bind(session_uri, "mock_publish", target_b, %{}, owner_ctx(owner_uri))

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListBindings.run([
            URI.to_string(session_uri),
            "--as",
            URI.to_string(owner_uri)
          ])
        end)

      assert output =~ "mock_publish"
      assert output =~ target_a
      assert output =~ target_b
      assert output =~ "binding_id"
    end

    test "empty session shows (no bindings)",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.ExternalMirror.ListBindings.run([
            URI.to_string(session_uri),
            "--as",
            URI.to_string(owner_uri)
          ])
        end)

      assert output =~ "no bindings"
    end
  end

  # ===========================================================================
  # helpers (mirrored from external_mirror_test.exs)
  # ===========================================================================

  defp ensure_adapter_registered(adapter, binding) do
    _ = AdapterRegistry.register(adapter)
    _ = BindingRegistry.register_module(adapter.adapter_id(), binding)

    %{behavior_module: behavior_module} = adapter.cap_subject()
    action = String.to_atom("allow_" <> adapter.adapter_id())

    try do
      :ok =
        Ezagent.CapabilityRegistry.register(
          Session,
          action,
          behavior_module
        )
    rescue
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_workers do
    case Process.whereis(RootSupervisor) do
      nil ->
        :ok

      _ ->
        DynamicSupervisor.which_children(RootSupervisor)
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          if is_pid(pid) do
            _ = DynamicSupervisor.terminate_child(RootSupervisor, pid)
          end
        end)
    end

    :ok
  end

  defp cleanup_session(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp spawn_owner_and_session(%URI{} = owner_uri, %URI{} = session_uri) do
    :ok = spawn_user(owner_uri, MapSet.new([Ezagent.Capability.admin_genesis_cap()]))

    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: owner_uri,
           behaviors: Session.behaviors()
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ws = Capability.workspace_of(session_uri)

    case ws do
      %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
      :any -> :ok
    end

    :ok = await_session_alive(session_uri, 50)

    requested = %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: session_uri,
      workspace_uri: Capability.workspace_of(session_uri),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }

    signed = Ezagent.Test.CapHelper.signed_cap!(session_uri, owner_uri, requested)
    :ok = Ezagent.Identity.absorb_cap(owner_uri, signed)
    await_owner_cap(owner_uri, signed, 50)
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp await_session_alive(_uri, 0), do: {:error, :timeout}

  defp await_session_alive(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        case Ezagent.ReadyGate.status(URI.to_string(uri)) do
          :ready -> :ok
          _ -> Process.sleep(20) && await_session_alive(uri, retries - 1)
        end

      _ ->
        Process.sleep(20)
        await_session_alive(uri, retries - 1)
    end
  end

  defp owner_ctx(owner_uri) do
    %{
      caller: owner_uri,
      caps: MapSet.new(Ezagent.Identity.list_caps_for(owner_uri)),
      reply: :ignore
    }
  end

  defp await_owner_cap(_owner_uri, _signed, 0), do: {:error, :timeout}

  defp await_owner_cap(owner_uri, signed, retries) do
    if signed in Ezagent.Identity.list_caps_for(owner_uri) do
      :ok
    else
      Process.sleep(20)
      await_owner_cap(owner_uri, signed, retries - 1)
    end
  end

  defp unique_user_uri(prefix) do
    Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_session_uri(prefix) do
    Ezagent.URI.new!(
      "session://team-alpha/default/#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  # Workaround silence-unused-alias warnings — these aliases are
  # used in the doc-shape comments above and may be tab-completed
  # in future edits.
  _ = Invocation
  _ = @workspace_uri
end
