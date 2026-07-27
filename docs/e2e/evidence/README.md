# evidence/ — 证据归档命名约定

每条 scenario 的证据放在 `scenario-NN/` 子目录,与 `docs/e2e/scenario-NN-*.md` 一一对应。

## 命名

```
分步证据(对应执行记录表步骤): docs/e2e/evidence/scenario-NN/sNN-stepK-<slug>.png
非分步证据(日志/审计/复用截图): docs/e2e/evidence/scenario-NN/sNN-<slug>.png
```

- `NN` — scenario 编号(补零两位,跟记录文件一致)
- `stepK` — 对应执行记录表里的步骤号(`step1`、`step2`…);**仅分步证据用**,日志/审计/复用类可省略
- `<slug>` — 一两词英文短描述(`login-form`、`echo-reply`、`mention-rejected`)
- 操作员视角截图惯例加 `-zyli` 后缀;observer 服务端对照加 `-confirmed`/`-observed`
- 扩展名:截图 `.png`;录屏 `.webm`;原始日志/JSON `.txt` / `.json`

例:`scenario-06/s06-step1-codex-reply-zyli.png`(分步,操作员视角)、`scenario-12/s12-invocations-audit.txt`(非分步,审计)

## 形态

- **主**:agent-browser 截图(LiveView)——硬规则,见 [`../guide.md` §4](../guide.md#4-取证规范硬规则)。
- **辅**:CLI/curl 原始输出建议直接贴进 `scenario-NN.md` 代码块;体积大或二进制(如审计导出)才落 `.txt`/`.json` 文件。

## 不要

- 不要把截图丢进 `scripts/e2e_recordings/`(那是旧 ad-hoc 区)——新记录统一进本目录。
- 不要只存日志截图当 UI 签收。
