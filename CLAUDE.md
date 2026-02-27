# CLAUDE.md — ezagent（核心引擎）

EZAgent 核心引擎，实现基于 CRDT 的协作协议。License: Apache 2.0。

## 技术栈

- **Rust** — 核心引擎实现
  - `yrs` (Yjs CRDT) — 数据同步
  - `zenoh` — P2P 网络通信
  - `PyO3` — Python 绑定
- **Python** — SDK 层（通过 PyO3 暴露 Rust API）

## 架构

核心引擎由 Bottom 层四原语 + Mid-layer 四实体组成：

```
Engine 组件:  Store → Bus → Clock → ACL
Backend:      存储后端（内存 / 磁盘持久化）
Built-in:     DataType, Hook, Annotation, Index
Mid-layer:    Identity, Room, Message, Timeline
```

详见 `docs/specs/bus-spec.md`。

## 开发指南

### Rust 规范

- 使用 `cargo fmt` 和 `cargo clippy` 保持代码风格一致
- 错误处理使用 `thiserror` 定义领域错误类型，避免 `unwrap()` / `expect()`
- 公开 API 必须有文档注释（`///`）
- 异步运行时使用 `tokio`

### Python 绑定

- PyO3 绑定代码放在独立模块中
- Python API 风格遵循 `docs/specs/py-spec.md`
- 包管理使用 `uv`（禁止 `pip`）
- 类型注解使用 Python 3.10+ 语法

### 测试

- 单元测试与源码同文件（`#[cfg(test)]` 模块）
- 集成测试放在 `tests/` 目录
- Fixture 数据参考 `docs/plan/fixtures.md`
- 运行测试：`cargo test`（Rust）、`uv run pytest`（Python）

## 关键概念

- **DataType** — CRDT 数据类型声明，是所有实体的构造原语
- **Hook** — 数据生命周期回调（pre-send / after-write / after-read）
- **Bus** — 消息总线，协调 Store、Clock、ACL
- **Socialware** — 正交维度（Role, Arena, Commitment, Flow），施加于 Mid-layer 实体

## Commit scope

在此目录下的变更使用 `ezagent` 作为 commit scope：

```
feat(ezagent): add new agent routing logic
fix(ezagent): handle CRDT merge conflict
```
