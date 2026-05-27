# Many EM tests reference `Ezagent.Entity.Session` / `User` / spawn paths
# owned by `ezagent_domain_chat` (Session+User Kinds live in chat for
# the deliberate one-way dep: chat depends on EM via Publisher contract,
# EM cannot dep on chat without forming a cycle — see mix.exs comment).
# At standalone `mix test` time only EM's own deps are auto-started, so
# Session module lookups crash with `:undef` and SpawnRegistry has no
# `entity://` / `session://` entries.
#
# Starting chat (and its identity+workspace prerequisites) here makes
# the test environment match the umbrella-from-root environment that
# the baseline used. The apps are not Mix deps (would form a cycle —
# see mix.exs comment) but their compiled artifacts ARE in the
# umbrella's shared `_build/` so we add them to the BEAM code path
# manually then ensure_all_started.
umbrella_lib = Path.expand("../../../_build/#{Mix.env()}/lib", __DIR__)

# Prepend EVERY umbrella sibling's ebin to the code path so transitive
# applications (e.g. chat depends on pty, identity, workspace) can be
# resolved. Cheap — just adds dirs, no .app load until ensure_all_started.
if File.dir?(umbrella_lib) do
  for sibling <- File.ls!(umbrella_lib) do
    ebin = Path.join([umbrella_lib, sibling, "ebin"])
    if File.dir?(ebin), do: Code.prepend_path(ebin)
  end
end

for app <- [:ezagent_domain_identity, :ezagent_domain_workspace, :ezagent_domain_chat] do
  {:ok, _} = Application.ensure_all_started(app)
end

ExUnit.start()
