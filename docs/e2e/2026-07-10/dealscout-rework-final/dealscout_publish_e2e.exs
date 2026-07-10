# dealscout 发布（deploy-seed 车道）—— 照 kanban 先例 /tmp/kanban_publish_e2e.exs：
# 1) server 节点内 SocialwareSeed.seed!（priv/socialware_seed → $EZAGENT_HOME/default/socialware）
# 2) server 节点内 ManifestSeed.scan_dir!（只含 dealscout 包的目录，避开 autoservice fail-loud）
# 用法：elixir --name pub@127.0.0.1 --cookie <runtime cookie> dealscout_publish_e2e.exs
node = :"ezagent_runtime@127.0.0.1"

seed_result = :erpc.call(node, Ezagent.Home.SocialwareSeed, :seed!, [], 60_000)
IO.inspect(seed_result, label: "seed!")

deploy_dir = :erpc.call(node, Path, :expand, ["~/.ezagent/default/socialware"], 10_000)
IO.puts("deploy dir: #{deploy_dir}")
IO.inspect(:erpc.call(node, File, :ls!, [deploy_dir], 10_000), label: "packages")

# 只含 dealscout 的扫描目录（symlink 指向部署目录真实包）
only = "/tmp/dealscout-deploy-only"
File.rm_rf!(only)
File.mkdir_p!(only)
File.ln_s!(Path.join(deploy_dir, "dealscout"), Path.join(only, "dealscout"))

scan =
  :erpc.call(node, Ezagent.Socialware.ManifestSeed, :scan_dir!, [only, [source: "deploy"]], 120_000)

IO.inspect(scan, label: "scan_dir! (in server node)")
