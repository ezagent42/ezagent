# Return — hello 迁部署级 seed 车道（栈②）

> **Task:** socialware-deploy-seed-hello（spec §5/§10）
> **Branch:** `feat/sw-hello-deploy-seed` · **PR:** #1233 · **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-08 09:14 +0800 · **deadline_status:** on_time
> **栈：** ① #1231 → ②（本）→ ③ #1236，基于 #1231

## 做了什么
hello reference 形态 → `ezagent_web/priv/socialware_seed/hello/manifest.yaml`；`Demo.Hello` 收敛为测试驱动（读 YAML + `:name` 覆盖 + `:role_name` legacy fixture）；删 boot 自发布（`ezagent_plugin_hello/application.ex`）；加 drift gate 防漂移。**整合 #1230**：补 `requires:[orchestrator]` 进 YAML + drift 冻结 shape。

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | reference→YAML，Demo.Hello 测试驱动，删 boot 自发布 | met | `demo_hello_test`+`manifest_yaml_test` 9/0 |
| 2 | drift gate（YAML parse 逐字段==reference，`^\[need-build\]` 逐字节） | met | `hello_manifest_drift_test` 5/0 |
| 3 | 整合 #1230 requires（YAML+drift 补 orchestrator） | met | drift 5/0 含 requires；#162 40/0 证带 requires 经车道 publish 正常 |
| 4 | **e2e 证明正常启动**（迁移必须） | met | `docs/e2e/2026-07-08/deploy-seed/`：home.init seed → boot `hello (deploy) → published`（DB pointer）→ world 可发现 → hello 匿名 public 页 200 渲染不跳 login。2 截图+README |
| 5 | 机器返还闸：CI 绿 + rebased on main | **partial** | rebased on `403a7e2ee` ✓；CI 快速 check pass，**full-suite pending** |

**Method friction:** rebase 到含 #1230 的 main 时 git 无文本冲突但 hello reference 迁 YAML 把 #1230 加的 `requires` 带删了（语义漏），现读代码发现并补进 YAML+drift。此前 subagent 提交未走 dev-together return——本轮补齐。

## Merge request
基于 #1231，合完 #1231 后本 PR rebase 即只剩 hello delta。
