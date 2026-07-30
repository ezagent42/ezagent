# MFU · MVO 组织图编辑器实施计划

**目标：** 让现有 MVO 展示多种真实组织结构，并让玩家在自由画布中画图、装入资源、验证和保存一个新 MVO。

**技术：** 单文件 HTML、CSS、原生 JavaScript、SVG 连线、Pointer Events、LocalStorage、Node.js、Playwright。

## 任务

1. 先扩展静态与浏览器测试，覆盖多种结构、编辑器入口、画布操作、验证与保存。
2. 将 MVO 数据统一为节点和连线；实现直线、分叉、汇合、中枢和回路缩略图。
3. 增加“自己设计 MVO”自由画布：新增、拖动、连接、删除和编辑步骤。
4. 增加资源选择、组织图验证、算力扣除与 AI 建议。
5. 验证通过后保存 MVO，并在首页和 LocalStorage 中持久化。
6. 运行静态、脚本语法、浏览器流程、视觉和 `mix precommit` 检查。

未经 ruihua 明确允许，不执行 commit 或 push。
