defmodule Mix.Tasks.Ezagent.Credential.Adopt do
  @shortdoc "Adopt an existing per-agent credential as a user's default source (§5.2)"
  @moduledoc """
  #17 cascade PR-0 (spec §5.2) — one-time migration that records an existing agent's
  credential as a user's DEFAULT credential source for a flavor, so future agents the
  user forks inherit it via the cascade (PR-1/PR-2).

  The write goes through the AUTHORIZED, cap-checked + audited chokepoint
  (`Ezagent.Credential.UserDefaultSource.set_via_dispatch/3`) under the operator
  (`system://mix-task`) principal — there is NO raw setter. Ambiguity is REFUSED: if
  more than one candidate is supplied, the task prints them and exits without guessing;
  the operator re-runs with a single explicit `--source`.

      mix ezagent.credential.adopt \\
          --owner entity://<ws>/user/<handle> \\
          --workspace <ws> \\
          --flavor cc \\
          --source entity://<ws>/agent/<existing-base>

  Multiple candidates (ambiguity check):

      mix ezagent.credential.adopt --owner ... --workspace <ws> --flavor cc \\
          --candidates entity://<ws>/agent/a1,entity://<ws>/agent/a2

  PR-0 keeps the task thin: candidate discovery is operator-supplied (`--source` or
  `--candidates`). The adoption logic (refuse-ambiguity + authorized dispatch) lives in
  `Ezagent.Credential.Adopt.adopt/5` and is unit-tested. A future PR may wire automatic
  discovery from the agent listing.
  """
  use Mix.Task

  @switches [
    owner: :string,
    workspace: :string,
    flavor: :string,
    source: :string,
    candidates: :string
  ]

  @impl Mix.Task
  def run(args) do
    # The adoption write routes through `Ezagent.Router.dispatch` on the
    # `:set_default_credential_source` Behavior, which needs more than core started:
    #   - `:ezagent_domain_identity` registers the UserDefaultCredentialSource Behavior
    #     (the cap-checked chokepoint) on the User Kind;
    #   - `:ezagent_domain_session` registers the `:flavor` UriQuery resolver
    #     used by the source-flavor validation.
    # Without these the dispatch would fail to route / resolve. Starting core alone is
    # insufficient. (Mirrors ezagent.user.create / ezagent.agent.create startup.)
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

    owner = require_opt!(opts, :owner)
    ws = require_opt!(opts, :workspace)
    flavor = require_opt!(opts, :flavor)

    candidates =
      cond do
        is_binary(opts[:source]) -> [opts[:source]]
        is_binary(opts[:candidates]) -> String.split(opts[:candidates], ",", trim: true)
        true -> Mix.raise("Provide --source <uri> or --candidates <uri,uri,...>")
      end

    caller = Ezagent.SystemPrincipal.uri("mix-task")
    caps = Ezagent.SystemPrincipal.caps(caller)

    case Ezagent.Credential.Adopt.adopt(owner, ws, flavor, candidates,
           caller: caller,
           caps: caps
         ) do
      {:ok, src} ->
        Mix.shell().info("adopted #{src} as #{owner}'s default #{flavor} source in #{ws}")

      {:error, {:ambiguous, many}} ->
        Mix.shell().error(
          "ambiguous — multiple candidate sources; re-run with a single --source:\n  " <>
            Enum.join(many, "\n  ")
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.raise("adoption failed: #{inspect(reason)}")
    end
  end

  defp require_opt!(opts, key) do
    case opts[key] do
      v when is_binary(v) and v != "" -> v
      _ -> Mix.raise("--#{key} is required")
    end
  end
end
