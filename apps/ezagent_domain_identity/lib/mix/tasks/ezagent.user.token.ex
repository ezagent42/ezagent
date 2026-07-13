defmodule Mix.Tasks.Ezagent.User.Token do
  @shortdoc "DEPRECATED (mostly) — use `mix ezagent user mint_token/list_tokens/revoke_token`"
  @moduledoc """
  > **DEPRECATED 2026-05-26 (HIGH-2 completion).**
  >
  > The dispatch-backed equivalents now exist via the new
  > `Ezagent.ActionSet.UserTokens` registered on User Kind. New
  > callers should use the auto-derived `mix ezagent` commands; they go
  > through `Ezagent.Invocation.dispatch/1` → step 5.5 CapBAC →
  > step 5.6 cross-workspace iso → audit telemetry.
  >
  >     # NEW — preferred paths:
  >     mix ezagent user mint_token   --user <uri> --label <name>
  >     mix ezagent user list_tokens  --user <uri>
  >     mix ezagent user revoke_token --user <uri> --token-id <id>
  >
  > **Carve-out preserved**: the first-admin-bootstrap mint
  > (chicken-and-egg — admin needs a token BEFORE they can dispatch
  > anything via `mix ezagent`) stays as `mix ezagent.user.token --mint`
  > per codex PR #304 MED finding. Operators bootstrapping a fresh
  > DB should use this task ONCE for the admin's first token, then
  > switch to `mix ezagent` for everything else (rotation, agent tokens,
  > etc.).
  >
  > Agent token minting (`entity://agent/...`) also stays here for
  > now — there's no LV path to model after, and the Behavior is
  > registered on User Kind only. Agent-token operations will be
  > addressed in a follow-up if/when the LV grows an agent-token
  > admin surface. Tracked in `docs/futures/todo.md`.

  Manage bearer tokens via the `entity_tokens` table (PR #142 SPEC v2
  §5.12).

  Replaces the old per-user-only `cli_token` flow with entity-agnostic
  token minting — works for any `entity://user/team-alpha/X` or
  `entity://agent/team-alpha/Y_Z` URI.

  ## Usage

      mix ezagent.user.token <entity_uri> --mint [--label NAME]
      mix ezagent.user.token <entity_uri> --revoke <token_id>
      mix ezagent.user.token <entity_uri> --list

  ## Examples

      mix ezagent.user.token entity://user/system/admin --mint --label cli-laptop
      mix ezagent.user.token entity://agent/team-alpha/cc_demo --mint
      mix ezagent.user.token entity://user/system/admin --list
      mix ezagent.user.token entity://user/system/admin --revoke 17

  ## After minting

  Pass the token to CLI calls:

      EZAGENT_USER_TOKEN=esr_pat_v1_<raw> mix ezagent session create test
      mix ezagent session create test --token=esr_pat_v1_<raw>
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        switches: [mint: :boolean, revoke: :integer, list: :boolean, label: :string]
      )

    uri_str =
      case args do
        [uri] -> uri
        _ -> Mix.raise("usage: mix ezagent.user.token <entity_uri> --mint|--list|--revoke ID")
      end

    Mix.Task.run("app.start")

    uri = Ezagent.URI.new!(uri_str)

    cond do
      opts[:mint] ->
        # Bootstrap-mint carve-out: this is the chicken-and-egg path
        # — admin needs a token BEFORE they can dispatch via `mix ezagent`
        # for any other op. The notice is gentle here (vs --list /
        # --revoke which always have a dispatch alternative).
        if mint_is_user?(uri) do
          Mix.shell().info("""
          NOTE: `mix ezagent.user.token --mint` is deprecated for non-bootstrap
          use as of 2026-05-26. Prefer the dispatch-backed equivalent for
          subsequent mints (CapBAC + audit):

              mix ezagent user mint_token --user <uri> --label <name>

          This bootstrap-mint mode remains for the very first admin token
          (chicken-and-egg: needed BEFORE `mix ezagent` can authenticate).
          """)
        end

        # `Token.mint/2` returns `{plain, row}` on success OR
        # `{:error, reason}` (unsupported entity URI). Both are
        # 2-tuples — the `{:error, _}` clause MUST come first, else
        # `{plain, row}` swallows it (binds plain=:error, row=reason)
        # and `row.id` crashes confusingly instead of the clean
        # Mix.raise. (dead-code audit 2026-05-21)
        case Ezagent.Entity.Token.mint(uri, label: opts[:label]) do
          {:error, reason} ->
            Mix.raise("mint failed: #{inspect(reason)}")

          {plain, row} ->
            Mix.shell().info("Minted token id=#{row.id} for #{uri_str}.")
            Mix.shell().info("")
            Mix.shell().info("  #{plain}")
            Mix.shell().info("")
            Mix.shell().info("Record this token now — it won't be shown again.")
            Mix.shell().info("Use via: EZAGENT_USER_TOKEN=<token> mix ezagent ...")
        end

      opts[:list] ->
        if mint_is_user?(uri) do
          Mix.shell().info("""
          NOTE: `mix ezagent.user.token --list` is deprecated as of 2026-05-26.
          Use the dispatch-backed equivalent (CapBAC + audit):

              mix ezagent user list_tokens --user <uri>

          This task still works but bypasses dispatch.
          """)
        end

        rows = Ezagent.Entity.Token.list(uri)

        if rows == [] do
          Mix.shell().info("No tokens for #{uri_str}.")
        else
          Mix.shell().info("Tokens for #{uri_str}:")

          for row <- rows do
            Mix.shell().info(
              "  id=#{row.id} label=#{inspect(row.label)} " <>
                "minted=#{row.inserted_at} last_used=#{inspect(row.last_used_at)}"
            )
          end
        end

      is_integer(opts[:revoke]) ->
        if mint_is_user?(uri) do
          Mix.shell().info("""
          NOTE: `mix ezagent.user.token --revoke` is deprecated as of 2026-05-26.
          Use the dispatch-backed equivalent (CapBAC + audit):

              mix ezagent user revoke_token --user <uri> --token-id <id>

          This task still works but bypasses dispatch.
          """)
        end

        :ok = Ezagent.Entity.Token.revoke(opts[:revoke])
        Mix.shell().info("Revoked token id=#{opts[:revoke]}.")

      true ->
        Mix.raise("must pass --mint, --list, or --revoke ID")
    end
  end

  # Only print deprecation notice for user URIs — agent token ops have
  # no dispatch alternative yet (the UserTokens Behavior is registered
  # on User Kind only). For agents the legacy task is still the
  # canonical path; notice would be misleading.
  defp mint_is_user?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp mint_is_user?(_), do: false
end
