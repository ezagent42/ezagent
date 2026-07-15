# Design Brief: Profile / 名片 socialware

> **目标**：独立的 Profile socialware 原型——用户展示/编辑个人名片，公开面供其他 socialware（dealscout/recruit）读取。
> **受众**：研发——理解 Profile 的产品形态和架构定位
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **架构定位**：socialware（`uses: ["hello"]`），与 recruit/dealscout 同级

---

## 1. 架构定位

Profile 是独立的 socialware，不是平台功能：

- **形式**：socialware（config-only Definition，`uses: ["hello"]`）
- **数据**：存储在 user identity（`entity://system/user/<name>`）的 config slice
- **公开面**：`session://system/profile/<name>` 对外暴露只读名片
- **被读取**：dealscout 匹配时读取名片信息（行业标签/资源/需求）提升匹配精度

## 2. 页面与流转

| 页面 | 作用 | 状态 |
|------|------|------|
| **index.html** | 名片主页：展示身份 + 行业标签 + 资源/需求。编辑模式 vs 查看模式 | 🆕 新建 |
| `../achievement-center.html` | 成就中心入口 | 🟡 已存在 |

### 流转

```
achievement-center.html "我的名片" → profile/index.html
  ① 查看模式（默认）：展示名片卡
  ② 编辑模式（点击编辑）：修改身份/标签/资源/需求
  ③ 保存 → 回 achievement-center

dealscout/index.html 匹配时读取 Profile 公开数据
recruit/index.html 可在 workspace 中引用 Profile
```

## 3. index.html 设计

### 页面结构

1. **名片卡**：头像 + 姓名 + 机构/角色 + 行业标签 + "我有什么" + "我在找什么"
2. **编辑模式**：点击编辑 → 表单修改各项 → 保存
3. **公开面**：简化的只读视图（供外部 socialware 引用）

### 视觉方向

- Ezagent Design System CDN
- 名片卡：白色卡片 + 22px 圆角 + 6层柔影
- 行业标签：pill 标签
- 编辑模式：内联表单

## 4. 与已有页面的关系

| 已有页面 | 本次是否改动 | 说明 |
|---------|------------|------|
| `achievement-center.html` | 是——加链接 | "角色档案" → profile/index.html |
| `mainsite.html` | 否 | 暂不接入（通过成就中心间接到达） |
| `doc/page-flow.md` | 是——更新 | 交付后更新 |

## 5. 不做的事

- ❌ 不实现真实后端（user config slice 存储、公开面 API）
- ❌ 不实现跨 session 的数据同步
- ❌ Profile 数据目前 mock 在 HTML 内
