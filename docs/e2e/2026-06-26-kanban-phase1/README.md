# Phase 1 e2e — UI 接线(config_surface + bind_session)

真 world UI(world.localhost:10042,admin 登录),headless chrome + CDP 截图。

- `01-plugins-kanban-entry.png` — **Task1**:Plugins 页 Kanban 卡片显示「看板」config 入口(config_surface;对比其它插件"no config")。
- `02-kanban-list.png` — /plugins/kanban 列表页(list-by-role 列出看板 agent)。
- `03-board-bind-session-control.png` — **Task2**:看板「本图配置」面板新增「绑定会话」输入+按钮(bind_session UI;认领/状态/挂PR 后向该会话播报触发接力 agent)。

单测:`application_test`(config_surface)+ `kanban_bind_session_test`(world 白名单),均绿。
