defmodule Mix.Tasks.Ezagent.Feishu.Bind do
  @shortdoc "Bind a Feishu open_id to a local ESR user URI"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch: calls `UserBinding.bind/3 + BindingPolicy.apply/2`
  > directly, so no CapBAC, no audit row, no cross-workspace check.
  > The LV `feishu_bindings_live.ex:90` uses the SAME functions (same
  > source ✓) but the CLI/LV split means the CLI never goes through
  > the dispatch step that LV could grow tomorrow. The `mix ezagent feishu
  > bind` equivalent does NOT exist yet — deleting this task today
  > would lose operator capability. Tracked in
  > `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: add the matching Behavior action + cap subject (NOT a bare FacadeRegistry op — codex PR #304 round-2 HIGH: that path bypasses Invocation.dispatch + caps + audit). mix ezagent auto-derives the CLI from interface/0. See the deferred-table guidance in docs/futures/todo.md HIGH-2
  > `(:feishu, :bind)` in `EzagentPluginFeishu.Application.start/2`
  > so `mix ezagent feishu bind --open-id … --user-uri … [--admin …]`
  > becomes available, then deprecate this task using the PR #302
  > stub pattern.

  Phase 6 PR 15 — admin CLI for Feishu identity bindings.

      mix ezagent.feishu.bind ou_6b11faf8e9... entity://user/team-alpha/linyilun
      mix ezagent.feishu.bind ou_xxx entity://user/team-alpha/linyilun --admin entity://user/system/admin

  After binding, `EzagentPluginFeishu.BindingPolicy.apply/2` ensures
  the bound user has `Ezagent.Entity.User.default_caps/0` (the
  baseline `kind=:session, behavior=:any` cap). With those caps the
  user can dispatch into sessions; per-session reach is controlled
  by the chat_id ↔ session_uri binding in `feishu_session_bindings`
  (see `mix ezagent.feishu.chat.bind`).

  Idempotent on the (open_id, user_uri) pair — rebinding to a
  different user replaces the prior binding silently.
  """
  use Mix.Task

  alias EzagentPluginFeishu.{BindingPolicy, UserBinding}

  @impl Mix.Task
  def run(argv) do
    {opts, positional, _} = OptionParser.parse(argv, switches: [admin: :string])

    {open_id, user_uri} =
      case positional do
        [oid, uri] -> {oid, uri}
        _ -> Mix.raise("usage: mix ezagent.feishu.bind <open_id> <user_uri> [--admin <admin_uri>]")
      end

    Mix.Task.run("app.start")

    admin_uri = opts[:admin] || "entity://user/system/admin"

    case UserBinding.bind(open_id, user_uri, admin_uri) do
      {:ok, _row} ->
        Mix.shell().info("✓ bound #{open_id} → #{user_uri} (by #{admin_uri})")

        case BindingPolicy.apply(user_uri, admin_uri) do
          :ok ->
            Mix.shell().info("✓ ensured default session-participation caps for #{user_uri}")

          err ->
            Mix.shell().error("⚠ binding saved but cap grant failed: #{inspect(err)}")
        end

      {:error, reason} ->
        Mix.raise("bind failed: #{inspect(reason)}")
    end
  end
end
