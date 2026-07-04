defmodule Mix.Tasks.Ezagent.User.SetPassword do
  @shortdoc "DEPRECATED — use `mix ezagent user set_password` (HIGH-2 completion)"
  @moduledoc """
  > **DEPRECATED 2026-05-26 (HIGH-2 completion — todo.md "CLI ↔ GUI parity").**
  >
  > The dispatch-backed equivalent now exists. New callers should use
  > the auto-derived `mix ezagent` command, which goes through
  > `Ezagent.Invocation.dispatch/1` → step 5.5 CapBAC → step 5.6
  > cross-workspace iso → audit telemetry. The cap shape is
  > `(:user, Ezagent.ActionSet.UserCredentials, :set_password)`; a
  > user can hold this against THEIR OWN URI for self-rotation, and
  > admin holds the `:any`-instance form for cross-user reset.
  >
  >     # NEW — preferred path:
  >     mix ezagent user set_password \\
  >         --user entity://user/<workspace>/<name> \\
  >         --password '<new-pw>'
  >
  > This legacy task is retained for muscle memory pending operator
  > migration (the PR #355 pattern). The internals still call
  > `Ezagent.Users.set_password/2` directly — same business logic,
  > but bypasses CapBAC + audit. **NOTE:** the legacy task is the
  > only path that works on a fresh DB BEFORE the admin user has a
  > token to authenticate `mix ezagent` calls — that bootstrap mode is
  > a narrow carve-out comparable to `mix ezagent.user.token --mint`
  > (see its moduledoc). New scripts should switch to `mix ezagent
  > user set_password`; this task will be removed in a future release
  > once the admin-bootstrap flow is replaced by the chicken-and-egg
  > `--mint` carve-out.

  Phase 4-completion Spec 05 §A.2.5 — set admin's first password
  (migration seeds admin with empty hash; this task is the path to
  enable admin login) or rotate any user's password.

  ## Usage

      mix ezagent.user.set_password entity://user/system/admin --password 'admin-pw'
      mix ezagent.user.set_password entity://user/team-alpha/allen --password 'new-pw'
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("""
    NOTE: `mix ezagent.user.set_password` is deprecated as of 2026-05-26.
    Use the dispatch-backed equivalent (CapBAC + audit + cross-workspace iso):

        mix ezagent user set_password \\
            --user <user-uri> \\
            --password '<new-pw>'

    This task still works (admin-bootstrap carve-out — first password
    must be set BEFORE the admin has a token for `mix ezagent`) but
    bypasses dispatch. New scripts should switch to `mix ezagent`.
    """)

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
