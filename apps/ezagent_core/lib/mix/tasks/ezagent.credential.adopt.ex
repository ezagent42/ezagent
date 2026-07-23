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

    # System-principal elimination (#154, 2026-06-19) — operator runs under the
    # real genesis admin entity (`User.admin_uri/0`), NOT the eliminated
    # `system://mix-task` ambient wildcard (shell access = admin authority,
    # in-VM trust §10.5). `Credential.Adopt.adopt/5` → `set_via_dispatch/3`
    # dispatches the NON-grant `:set_default_credential_source` action on the
    # OWNER's User Kind; the INLINE `cap(:user, UserDefaultCredentialSource,
    # :set_default_credential_source)` scoped to that owner is the step-5.5
    # authorizer. `granted_by` = `admin_uri` (a real entity per #154, provenance
    # only on an inline authorizer never routed through `Ezagent.Identity.Grant`).
    # `Ezagent.Entity.User` lives in `ezagent_domain_identity` (not a compile
    # dep of `ezagent_core`); resolve at RUNTIME via `apply/3` (same pattern as
    # `ezagent.stress.ex`). The app is started by this Mix task, so it resolves.
    admin_uri = apply(Module.concat([:Ezagent, :Entity, :User]), :admin_uri, [])
    owner_uri = Ezagent.URI.new!(owner)

    target =
      Ezagent.URI.with_action(
        owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    caps =
      case Ezagent.Cap.issue_for_action({:admin, admin_uri}, admin_uri, target) do
        {:ok, cap} -> [cap]
        {:error, reason} -> Mix.raise("credential-adopt cap issuance failed: #{inspect(reason)}")
      end

    case Ezagent.Credential.Adopt.adopt(owner, ws, flavor, candidates,
           caller: admin_uri,
           authenticated_principal: admin_uri,
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
