# :live_miro 标签默认排除（需真实网络 + miro.yaml 凭证）；显式 --include live_miro 跑。
ExUnit.start(exclude: [:live_miro])
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
