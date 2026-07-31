# MFU Demo

打开 [`index.html`](index.html) 可以进入当前 Demo、历史版本、功能性教学 Demo 和 living docs。

## 目录

```text
mfu-demo/
├── index.html
├── living-docs/       跨版本持续维护的单一事实源
├── pending-decisions/ 尚未确认的产品与机制问题
├── versions/          完整游戏 Demo，按版本号归档
└── concept-demos/     独立的功能性教学 Demo
```

## 当前版本

- [`versions/v0.3/demo/MFU-多角色组织世界-v0.3.html?role=incubator`](versions/v0.3/demo/MFU-多角色组织世界-v0.3.html?role=incubator)：当前多角色共享世界 Demo；
- [`versions/v0.2/demo/MFU-MVO组织牧场-v0.2-可玩原型.html`](versions/v0.2/demo/MFU-MVO组织牧场-v0.2-可玩原型.html)：上一版组织牧场快照。

v0.3 可以通过 URL 直接打开不同角色：

- `?role=incubator`：孵化器运营者；
- `?role=school`：学校课程负责人；
- `?role=enterprise`：企业创新负责人；
- `?role=student`：学生创业者。

## Living docs

- [`living-docs/platform-concept-model.html`](living-docs/platform-concept-model.html)：平台概念及其关系（阅读版）；
- [`living-docs/skill-tree.html`](living-docs/skill-tree.html)：个人、公司和角色成长树（阅读版）；
- [`living-docs/infographics/MFU-v0.15-机制信息图.html`](living-docs/infographics/MFU-v0.15-机制信息图.html)：持续解释平台宏观机制的信息图。

对应的 `.md` 文件是编辑时使用的单一事实源；运行 `living-docs/render.sh` 可重新生成带 UTF-8 编码声明的 HTML 阅读版。

只有跨版本持续维护的内容放入 `living-docs`。旧 GDD、审计和 Demo 不因新版本变化而回写。

## 功能性教学 Demo

Card Array 不属于完整游戏版本：

- [`concept-demos/card-array/demo/MFU-协作阵列-v0.1-可玩原型.html`](concept-demos/card-array/demo/MFU-协作阵列-v0.1-可玩原型.html)
- [`concept-demos/card-array/docs/core-gameplay-card-array.md`](concept-demos/card-array/docs/core-gameplay-card-array.md)
- [`concept-demos/card-array/docs/student-opc-lifecycle-roadmap.md`](concept-demos/card-array/docs/student-opc-lifecycle-roadmap.md)

它用于让新用户从零理解卡牌编排与任务协作，未来仍可以独立演示。

订单全生命周期也是独立概念 Demo：

- [`concept-demos/order-lifecycle/01-issuer.html`](concept-demos/order-lifecycle/01-issuer.html)
- [`concept-demos/order-lifecycle/README.md`](concept-demos/order-lifecycle/README.md)

## 待决策

未确定的机制统一登记在 [`pending-decisions/`](pending-decisions/README.md)，不得直接写成正式平台规则。

## 测试

每个版本或概念 Demo 的测试与对应产物放在同一目录下的 `tests/` 中。
