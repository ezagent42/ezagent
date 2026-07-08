# World 场景 06(执行记录):成员移除与 Socialware 卸载

- 状态: pending, waiting for agent-browser run on a live server
- 验证面: world UI / session management panel / socialware uninstall
- 执行人: Codex + agent-browser
- 环境: branch work/sw-uninstall-ui, server http://world.localhost:10042

## 前置条件

- admin 已登录: admin@ezagent.chat / worlddev
- workspace: workspace://system
- 已 seed 内置 socialware catalog
- 服务启动在 http://world.localhost:10042

## 验收目标

- 成员面板的逐成员移除按钮会弹出确认框;确认后该成员从列表消失。
- 创建一个安装 socialware 的 session 后,成员面板按 socialware 显示已装项。
- 点击已装项的卸载按钮并确认后,该 session 的 socialware 成员、session-created routing rules、socialware view tabs 全部消失。

## 自动化运行(agent-browser runbook)

- 入口 URL: http://world.localhost:10042/sessions
- 自建 session: world-e2e-socialware-uninstall
- 证据目录: docs/e2e/evidence/world-scenario-06-socialware-uninstall/

1. record start: world-s06-socialware-uninstall.webm
2. navigate to /sessions and assert the Sessions surface renders.
3. create a new session named world-e2e-socialware-uninstall using template default and socialware socialware.
4. wait until the URL contains world-e2e-socialware-uninstall.
5. open the members panel and assert data-world-socialware-uninstall-panel exists.
6. if a non-current member row is present, click [data-world-remove-member], assert the browser confirm appears, accept it, and assert that member label disappears.
7. assert at least one [data-world-socialware-uninstall-button] exists under data-world-socialware-uninstall-panel.
8. click [data-world-socialware-uninstall-button], accept the browser confirm, and wait until data-world-socialware-uninstall-panel is absent.
9. assert no socialware/page view tab remains, and the advanced rules count is 0.
10. screenshot final state and record stop.

## 建议 agent-browser 脚本骨架

- agent-browser --session world-login-e2e record start docs/e2e/evidence/world-scenario-06-socialware-uninstall/world-s06-socialware-uninstall.webm
- agent-browser --session world-login-e2e open http://world.localhost:10042/sessions
- agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-06-socialware-uninstall/world-s06-step01-sessions.png
- agent-browser --session world-login-e2e click Create-a-new-session
- agent-browser --session world-login-e2e fill Name world-e2e-socialware-uninstall
- agent-browser --session world-login-e2e choose socialware install option
- agent-browser --session world-login-e2e click Create
- agent-browser --session world-login-e2e wait for URL containing world-e2e-socialware-uninstall
- agent-browser --session world-login-e2e open members panel
- agent-browser --session world-login-e2e assert selector [data-world-socialware-uninstall-panel]
- agent-browser --session world-login-e2e click [data-world-socialware-uninstall-button] and accept dialog
- agent-browser --session world-login-e2e wait until selector [data-world-socialware-uninstall-panel] is absent
- agent-browser --session world-login-e2e screenshot docs/e2e/evidence/world-scenario-06-socialware-uninstall/world-s06-step03-uninstalled.png
- agent-browser --session world-login-e2e record stop

## 清理

- 删除自建 session 或重置 DB 后重新 seed。

