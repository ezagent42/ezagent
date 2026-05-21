defmodule Mix.Tasks.Ezagent.User.Token do
  @shortdoc "Mint or revoke bearer tokens for an entity (user or agent)"
  @moduledoc """
  Manage bearer tokens via the `entity_tokens` table (PR #142 SPEC v2
  §5.12).

  Replaces the old per-user-only `cli_token` flow with entity-agnostic
  token minting — works for any `entity://user/default/X` or
  `entity://agent/default/Y_Z` URI.

  ## Usage

      mix ezagent.user.token <entity_uri> --mint [--label NAME]
      mix ezagent.user.token <entity_uri> --revoke <token_id>
      mix ezagent.user.token <entity_uri> --list

  ## Examples

      mix ezagent.user.token entity://user/system/admin --mint --label cli-laptop
      mix ezagent.user.token entity://agent/default/cc_demo --mint
      mix ezagent.user.token entity://user/system/admin --list
      mix ezagent.user.token entity://user/system/admin --revoke 17

  ## After minting

  Pass the token to CLI calls:

      EZAGENT_USER_TOKEN=esr_pat_xxx mix esr session create test
      mix esr session create test --token=esr_pat_xxx
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

    uri = URI.parse(uri_str)

    cond do
      opts[:mint] ->
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
            Mix.shell().info("Use via: EZAGENT_USER_TOKEN=<token> mix esr ...")
        end

      opts[:list] ->
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
        :ok = Ezagent.Entity.Token.revoke(opts[:revoke])
        Mix.shell().info("Revoked token id=#{opts[:revoke]}.")

      true ->
        Mix.raise("must pass --mint, --list, or --revoke ID")
    end
  end
end
