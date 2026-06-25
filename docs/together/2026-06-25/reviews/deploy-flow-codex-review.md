# Codex 对抗性评审 — deploy flow plan/spec (2026-06-25)

codex-cli 0.142.0,静态评审 docs/superpowers/{specs,plans}/2026-06-25-deploy-flow*。15 findings(4 致命 / 6 高 / 5 中)。

## 致命
1. infra + channel compose 合并跑 → 合成单 project,破坏隔离。infra 独立 `up`,channel 只用自己 compose 经 external `ezagent_edge` 连。
2. deploy.sh include infra 文件却不载 .env.infra → TS_AUTHKEY/CF_API_TOKEN 插值失败。infra 独立生命周期。
3. beta/stable 缺 SHA 镜像会重 build → 违反 build-once。beta/stable 必须 fail-closed。
4. re-tag 后 `up -d --no-build` 未 `--force-recreate` → 可能跑旧容器,迁移不执行。需 force-recreate + 校验运行容器 image ID。

## 高
5. 健康检查 jq 解析 compose ps(array vs stream)脆弱 → 改 `docker inspect .State.Health.Status`。
6. rollback 同 #4(无 force-recreate / 无校验);首部署 PREV=none 要 fail+报警。
7. self-hosted runner 安全:branch protection、environments 审批、`permissions: contents: read`、专用低权用户。
8. build 走 GFW:host proxy(host.docker.internal:7897)须作 runner 前置并验证(mihomo 是 edge 内服务,build 时还没它)。
9. .gitignore 现状只忽略根 .env → 必须先补 `docker/.env`、`docker/.env.*`、`!docker/.env.channel.example`、`docker/secrets-*/`。
10. EZAGENT_COOKIE 必须 == RELEASE_COOKIE(现有 runtime/rpc 依赖);计划生成两个不同值 = bug。

## 中
11. Caddy/ts 共享 netns 的 DNS 解析假设未验证 → 加 `docker exec <ts> getent hosts ezagent-nightly` + 同 netns curl upstream。
12. backup 硬编码容器/卷名(依赖精确 project 名)→ 用 `compose exec -T postgres` + `docker volume inspect`。
13. backup manifest 应记 full git SHA + 运行容器 image digest + dump 起止时间;非原子要标注。
14. stable cloudflared config 丢了 originRequest(connectTimeout/tcpKeepAlive)→ 迁移时保留。
15. launchd 路径硬编码开发 worktree → 由安装脚本渲染最终 checkout 绝对路径。
