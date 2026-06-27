# AutoService Tier-1 IN-NODE serve-seed — run INSIDE the serving BEAM.
#
# The public_view session must be LIVE in the same BEAM that serves web: the
# public ChatFeedController gates on the live session slice BEFORE the join that
# would demand-spawn it (ezagent-socialware local-e2e-recipe §2). Seeding in a
# separate `mix run` BEAM then starting the server leaves the session cold → the
# anon customer gets a 302.
#
# Run it loaded in-node (keep stdin open so iex doesn't EOF-halt the server):
#
#   export EZAGENT_HOME=/tmp/ezagent_autosvc_e2e MIX_ENV=dev PORT=10042 PHX_HOST=0.0.0.0
#   nohup sh -c 'tail -f /dev/null | iex --dot-iex scripts/autoservice_tier1_serve_seed.exs -S mix phx.server' \
#     > /tmp/autosvc_server.log 2>&1 &
#   mix assets.build      # builds customer_app.js + customer.css
#
# On the live node the kb recipe + native/cc flavors + orchestrator role are
# already registered at boot, so `register_recipes: false` (the default).

Code.require_file(Path.expand("autoservice_tier1_seed.exs", __DIR__))

case Ezagent.AutoService.Tier1Seed.seed([]) do
  {:ok, seed} ->
    links = Ezagent.AutoService.Tier1Seed.deep_links(seed)

    IO.puts("""

    === AutoService Tier-1 seed complete ===
    workspace        : #{URI.to_string(seed.workspace_uri)}
    kb-agent         : #{URI.to_string(seed.kb_agent_uri)}  (fact: #{Ezagent.AutoService.Tier1Seed.kb_fact_token()})
    AutoService agent: #{URI.to_string(seed.autoservice_agent_uri)}  (status: #{inspect(seed.autoservice_agent_status)})
    session          : #{URI.to_string(seed.session_uri)}
    route            : always(in_session)→AutoService-agent  id=#{inspect(seed.rule_id)}

    customer (anon)  : #{links.customer}
    operator console : #{links.operator}

    S3 probe query   : "#{Ezagent.AutoService.Tier1Seed.kb_probe_query()}"
    (the answer must contain #{Ezagent.AutoService.Tier1Seed.kb_fact_token()} — a fact ONLY in the corpus)
    """)

  {:error, reason} ->
    IO.puts(:stderr, "\n!!! AutoService Tier-1 seed FAILED: #{inspect(reason)}\n")
end
