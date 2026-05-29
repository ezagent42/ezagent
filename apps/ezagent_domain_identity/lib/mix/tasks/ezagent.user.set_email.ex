defmodule Mix.Tasks.Ezagent.User.SetEmail do
  @shortdoc "Bind an email address to an existing User principal (operator carve-out)"
  @moduledoc """
  Operator carve-out — set or update the `email` attribute on an
  existing User's `entity_profiles` row.

  ## Why this task exists

  Allen 2026-05-26: `linyilun` was provisioned via `mix ezagent.user.create`
  and `mix ezagent.user.set_password`, but neither task touches
  `entity_profiles` — `email` stayed NULL. When Allen tried `/login`
  magic-link with his Gmail, `Ezagent.Registration.principal_for_email/1`
  returned `:none` and the request was silently dropped per the
  anti-enumeration invariant (see
  `apps/ezagent_web/test/integration/magic_link_invariants_test.exs`).

  The companion `mix ezagent.auth.magic_link <email>` CLI prints the
  drop reason for diagnosis, but had no remediation tool — operators
  had to drop into IEx and call `Ezagent.Entity.Profile.upsert/1`
  directly. This task is the operator-grade remediation.

  ## Scope

  This task is the bootstrap / admin-debug counterpart to a future
  `mix ezagent user set_email` (dispatch-backed, CapBAC + audit). It
  bypasses dispatch — same carve-out as `mix ezagent.user.set_password`,
  appropriate for:

  - First-time admin setup before tokens exist
  - Operator emergency repair on a fresh DB
  - Test fixtures (though tests should prefer `Profile.upsert/1`)

  ## Usage

      mix ezagent.user.set_email entity://user/system/linyilun \\
          --email allen@example.com

      # Optional: set display_name at the same time
      mix ezagent.user.set_email entity://user/system/linyilun \\
          --email allen@example.com --display-name "Allen Woods"

  ## Behavior

  1. Validates the URI as `entity://user/<workspace>/<name>` (SPEC v3 §3)
  2. Confirms a row exists in `users` for that URI (no orphan profiles)
  3. Reads existing `entity_profiles` row if any (preserves `display_name`
     when the operator doesn't override)
  4. Falls back to the URI's last path segment as `display_name` if no
     profile row exists and `--display-name` is omitted
  5. Calls `Ezagent.Entity.Profile.upsert/1` (which lowercases + trims
     the email and enforces the `entity_profiles_email_index` uniqueness
     constraint)

  ## Exit codes

  - 0: profile upserted; `magic_link silent_drop` will no longer fire
       for this email (existing-principal branch wins)
  - 1: user not found, malformed URI, or email collides with another
       principal's profile (the email index is unique)
  """

  use Mix.Task

  alias Ezagent.Entity.Profile
  alias Ezagent.Users

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [email: :string, display_name: :string]
      )

    with [user_uri_str] <- positional,
         email when is_binary(email) and email != "" <- Keyword.get(opts, :email) do
      do_set(user_uri_str, email, Keyword.get(opts, :display_name))
    else
      _ ->
        Mix.raise("""
        usage: mix ezagent.user.set_email <user_uri> --email <addr> [--display-name <name>]

        Example:
          mix ezagent.user.set_email entity://user/system/linyilun \\
              --email allen@example.com
        """)
    end
  end

  defp do_set(user_uri_str, email, override_display_name) do
    with {:ok, user_uri} <- parse_uri(user_uri_str),
         :ok <- check_user_exists(user_uri),
         display_name <- resolve_display_name(user_uri_str, override_display_name),
         {:ok, profile} <-
           Profile.upsert(%{
             entity_uri: user_uri_str,
             display_name: display_name,
             email: email
           }) do
      Mix.shell().info("✓ email set for #{user_uri_str}")
      Mix.shell().info("  email: #{profile.email}")
      Mix.shell().info("  display_name: #{profile.display_name}")
      Mix.shell().info("  workspace_uri: #{profile.workspace_uri}")
      Mix.shell().info("")
      Mix.shell().info("Magic-link login should now resolve this email to the existing principal.")
      Mix.shell().info("Verify with: mix ezagent.auth.magic_link #{profile.email}")
    else
      {:error, %Ecto.Changeset{} = cs} ->
        Mix.raise("set_email failed: #{format_changeset_errors(cs)}")

      {:error, reason} ->
        Mix.raise("set_email failed: #{inspect(reason)}")
    end
  end

  defp parse_uri(s) when is_binary(s) do
    # Mirror ezagent.user.create's URI guard so the SPEC v3 §3 error
    # surfaces cleanly for 2-segment / non-`user` URIs.
    try do
      uri = Ezagent.URI.new!(s)

      case uri do
        %URI{scheme: "entity", host: "user", path: "/" <> _rest} ->
          {:ok, uri}

        _ ->
          {:error, {:bad_uri, s, "expected entity://user/<workspace>/<name>"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

  defp check_user_exists(%URI{} = uri) do
    case Users.get_by_uri(URI.to_string(uri)) do
      nil -> {:error, {:user_not_found, URI.to_string(uri)}}
      _ -> :ok
    end
  end

  # Operator override wins. Otherwise: keep an existing profile's
  # display_name, or fall back to the URI's last path segment so a
  # brand-new profile row meets the NOT NULL constraint without forcing
  # the operator to pass `--display-name`.
  defp resolve_display_name(_user_uri_str, override) when is_binary(override) and override != "",
    do: override

  defp resolve_display_name(user_uri_str, _override) do
    case Profile.get(user_uri_str) do
      %Profile{display_name: name} when is_binary(name) and name != "" -> name
      _ -> derive_slug(user_uri_str)
    end
  end

  defp derive_slug(user_uri_str) do
    user_uri_str
    |> String.split("/")
    |> List.last()
    |> case do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> "user"
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end
end
