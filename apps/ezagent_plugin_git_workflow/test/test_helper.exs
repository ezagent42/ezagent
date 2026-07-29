# 真实 GitHub 往返（test/e2e/github_live_test.exs）默认不跑：需要凭证 + 网络。
# 跑法见该文件 moduledoc 与 docs/guide/github-plugin-config.md。
ExUnit.start(exclude: [:live_github])
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)

# Slice P4b — the authorization-surface suite dispatches real, signed
# capabilities into `Ezagent.Entity.GitTaskAccess`, so `Cap.Authorize`'s
# PRINCIPAL gate runs for real. Under the production loader
# (`Ezagent.Identity`) a workspace agent that owns no `users` row loads an
# empty held-cap set and every dispatch dies at `:holder_revoked` before the
# policy layer is ever reached — which is precisely the layer this slice
# exists to test.
#
# `apps/ezagent_domain_git/test/test_helper.exs` solved this for the same Kind
# with the same swap; reusing its loader keeps ONE definition of "a git task
# worker is a current principal" instead of two that can drift.
#
# This weakens nothing under test. The loader answers CURRENCY only; a
# candidate capability still has to survive the TARGET gate (signature
# verified against the target's current authority row, bound to the
# authenticated holder), so the attacker in `authorization_surface_test.exs`
# clears the principal gate exactly as an un-revoked real agent would and is
# then answered — or not — by the layer under examination.
cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)

Application.put_env(
  :ezagent_core,
  Ezagent.Cap,
  Keyword.put(
    cap_config,
    :authority_loader,
    Ezagent.DomainGit.TestSupport.GitCapAuthorityLoader
  )
)

ExUnit.after_suite(fn _result ->
  Application.put_env(:ezagent_core, Ezagent.Cap, cap_config)
end)
