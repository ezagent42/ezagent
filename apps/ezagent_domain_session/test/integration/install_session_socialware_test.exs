defmodule EzagentDomainInstanceMessage.Integration.InstallSessionSocialwareTest do
  @moduledoc """
  Regression gate for PR #1317 (`fix/install-transaction-silent-success`).

  `install_session_socialware/2` used to read
  `Session.read_template_working_copy/1` directly and materialize whatever
  `member_declarations` it found. When the Session Kind is NOT in the registry
  (dead / never-created), that read returns the EMPTY default — indistinguishable
  from "this template declares no agent role slots" — so the install materialized
  NOTHING yet returned `:ok` (silent success).

  The fix demands the durable declaration: a working copy with no `%URI{}`
  `:session_template_uri` must return `{:error, {:no_template_declaration, uri}}`
  (LOUD), never `:ok`.

  This test FAILS against the pre-fix code (which returns `:ok`) and PASSES
  against the fix.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.KindRegistry
  alias EzagentDomainInstanceMessage.SessionCreator

  setup do
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "install_session_socialware/2 with no durable template declaration" do
    test "returns {:error, {:no_template_declaration, uri}}, never a silent :ok" do
      short = "install-no-decl-#{System.unique_integer([:positive])}"
      session_uri = Ezagent.URI.session("system", "default", short)
      workspace_uri = Ezagent.URI.workspace(:system)

      on_exit(fn -> terminate_if_alive(session_uri) end)

      # Precondition: an uninstalled/dead Session Kind yields the EMPTY default
      # working copy — `session_template_uri` is nil. This is the exact state
      # the old code treated as "declares no roles" and silently succeeded on.
      assert Map.get(Session.read_template_working_copy(session_uri), :session_template_uri) ==
               nil

      # The invariant: installing socialware against that state must FAIL LOUD.
      # (Pinning the full tuple with ^session_uri proves the error is the
      # missing-declaration branch, not an incidental spawn/other error — the
      # arity-2 call passes an explicit %URI{} workspace, so `:no_template_declaration`
      # is the only reachable error.)
      assert {:error, {:no_template_declaration, ^session_uri}} =
               SessionCreator.install_session_socialware(session_uri, workspace_uri)
    end
  end

  defp terminate_if_alive(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.SessionSupervisor,
            pid
          )
        end

      _ ->
        :ok
    end
  end
end
