defmodule Mix.Tasks.Ezagent.User.SetPassword do
  @shortdoc "Set or rotate an ESR User's password"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch: calls `Ezagent.Users.set_password/2` directly,
  > so no CapBAC, no audit row, no cross-workspace check. The `mix esr
  > user set_password` equivalent does NOT exist yet — deleting this
  > task today would lose operator capability (including admin's
  > first-password bootstrap). Tracked in
  > `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: register a FacadeRegistry op
  > `(:user, :set_password)` so `mix esr user set_password --uri …
  > --password …` becomes available, then deprecate this task using
  > the PR #302 stub pattern.

  Phase 4-completion Spec 05 §A.2.5 — set admin's first password
  (migration seeds admin with empty hash; this task is the path to
  enable admin login) or rotate any user's password.

  ## Usage

      mix ezagent.user.set_password entity://user/system/admin --password 'admin-pw'
      mix ezagent.user.set_password entity://user/default/allen --password 'new-pw'
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    {opts, positional, _} =
      OptionParser.parse(args, strict: [password: :string])

    with [user_uri_str] <- positional,
         password when is_binary(password) and password != "" <-
           Keyword.get(opts, :password) do
      do_set(user_uri_str, password)
    else
      _ ->
        Mix.raise("""
        usage: mix ezagent.user.set_password <user_uri> --password <pw>
        """)
    end
  end

  defp do_set(user_uri_str, password) do
    case Ezagent.Users.set_password(user_uri_str, password) do
      {:ok, _decoded} ->
        Mix.shell().info("✓ password set for #{user_uri_str}")

      {:error, :not_found} ->
        Mix.raise("user #{user_uri_str} not found")

      {:error, reason} ->
        Mix.raise("set_password failed: #{inspect(reason)}")
    end
  end
end
