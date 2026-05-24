defmodule Mix.Tasks.Ezagent.User.Token do
  @shortdoc "Mint or revoke bearer tokens for an entity (user or agent)"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — SPLIT classification
  > (codex PR #304 round-2 MED).**
  >
  > Only `--mint` of the FIRST-admin-bootstrap token genuinely needs
  > to stay outside dispatch (chicken-and-egg: that token IS what
  > `mix esr` uses to authenticate). Round-1 classified the WHOLE
  > task as Category A; codex round-2 correctly observed that the
  > task ALSO mints tokens for arbitrary users, lists them, and
  > revokes them — all auth-boundary operations that have no
  > bootstrap excuse for skipping CapBAC + audit.
  >
  > **Bootstrap mode (`--mint` of the very first admin user when
  >  no operator token exists):** Category A — STAYS here.
  >
  > **All other modes (`--mint` for arbitrary entities, `--list`,
  >  `--revoke`):** Category C — DEFERRED to `mix esr user token
  > mint|list|revoke` (each backed by a real `Ezagent.Entity.User`
  > Behavior action + cap subject; `mix esr` auto-derives the CLI
  > from `interface/0`). NOT a bare FacadeRegistry op — that path
  > bypasses dispatch + caps + audit. See `docs/futures/todo.md`
  > § "CLI ↔ GUI parity" deferred table for the per-mode rows.
  >
  > Until the deferred Behavior actions land, the non-bootstrap
  > modes here are TRACKED BYPASS DEBT, not Category A. The
  > invariant-test pattern an implementer will need: keep
  > Category A allowlists narrow enough that token admin
  > operations cannot be silently exempted.

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
