defmodule Mix.Tasks.Ezagent.Invite do
  @shortdoc "Mint / list / revoke self-registration invite codes (task #87)"
  @moduledoc """
  Admin CLI for invite codes (task #87 Decision 10). Runs in-VM — this is the
  trusted boundary for invite administration (a web/UI surface would require an
  admin cap; that is a follow-up).

  ## Usage

      # Mint a code for a workspace (prints the raw code — share it once)
      mix ezagent.invite mint --workspace team-alpha [--role member] \\
          [--max-uses 20] [--expires-in-days 14]

      # List codes (optionally scoped to a workspace)
      mix ezagent.invite list [--workspace team-alpha]

      # Revoke a code (stops future consumes; existing users unaffected)
      mix ezagent.invite revoke <code>

  The minted code carries the **authoritative** target workspace: a registrant
  who uses it joins exactly that workspace.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [workspace: :string, role: :string, max_uses: :integer, expires_in_days: :integer]
      )

    case positional do
      ["mint" | _] -> mint(opts)
      ["list" | _] -> list(opts)
      ["revoke", code | _] -> revoke(code)
      _ -> Mix.raise(usage())
    end
  end

  defp mint(opts) do
    workspace = Keyword.get(opts, :workspace) || Mix.raise("--workspace is required for mint")
    ws_uri = workspace |> Ezagent.URI.workspace() |> Ezagent.URI.stable_key()

    attrs =
      %{
        workspace_uri: ws_uri,
        created_by: URI.to_string(Ezagent.Entity.User.admin_uri()),
        role: Keyword.get(opts, :role),
        max_uses: Keyword.get(opts, :max_uses, 1)
      }
      |> maybe_expiry(Keyword.get(opts, :expires_in_days))

    case Ezagent.Entity.InviteCode.mint(attrs) do
      {:ok, {code, row}} ->
        Mix.shell().info("✓ invite minted")
        Mix.shell().info("  code:       #{code}")
        Mix.shell().info("  workspace:  #{row.workspace_uri}")
        Mix.shell().info("  max_uses:   #{row.max_uses}")
        Mix.shell().info("  expires_at: #{row.expires_at || "never"}")

      {:error, cs} ->
        Mix.raise("mint failed: #{inspect(cs.errors)}")
    end
  end

  defp list(opts) do
    codes =
      case Keyword.get(opts, :workspace) do
        nil ->
          Ezagent.Entity.InviteCode.list()

        ws ->
          Ezagent.Entity.InviteCode.list(Ezagent.URI.workspace(ws) |> Ezagent.URI.stable_key())
      end

    if codes == [] do
      Mix.shell().info("(no invite codes)")
    else
      Enum.each(codes, fn c ->
        status =
          cond do
            c.revoked_at -> "revoked"
            c.used_count >= c.max_uses -> "exhausted"
            true -> "active"
          end

        Mix.shell().info(
          "#{c.code}  #{c.workspace_uri}  #{c.used_count}/#{c.max_uses}  #{status}"
        )
      end)
    end
  end

  defp revoke(code) do
    case Ezagent.Entity.InviteCode.revoke(code) do
      {:ok, _} -> Mix.shell().info("✓ revoked #{code}")
      {:error, :not_found} -> Mix.raise("no such code: #{code}")
    end
  end

  defp maybe_expiry(attrs, nil), do: attrs

  defp maybe_expiry(attrs, days) when is_integer(days) do
    Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), days * 86_400, :second))
  end

  defp usage do
    """
    usage:
      mix ezagent.invite mint --workspace <name> [--role member] [--max-uses N] [--expires-in-days D]
      mix ezagent.invite list [--workspace <name>]
      mix ezagent.invite revoke <code>
    """
  end
end
