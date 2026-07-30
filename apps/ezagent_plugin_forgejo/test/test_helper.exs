# 真实 Forgejo 往返(test/e2e/forgejo_live_test.exs)默认不跑：需要凭证 + 网络，
# 而且会在目标仓库上真的建分支和 PR。跑法见该文件 moduledoc。
# 与 :live_github / :live_miro 同一先例。
ExUnit.start(exclude: [:live_forgejo])
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
