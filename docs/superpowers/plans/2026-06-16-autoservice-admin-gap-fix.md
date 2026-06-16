# AutoService Admin UI — 功能对齐修复计划

> 对比旧版 AutoService-dev-a，逐功能修复 CRITICAL 差距
> 共 7 个 CRITICAL 问题需立即修复

---

## 功能差异总览

| 严重度 | 数量 | 关键项 |
|:--:|:--:|------|
| **CRITICAL** | 7 | KB chunking、PDF/XLSX语义提取、异步 ingest、ETag、sandbox diff、Skill frontmatter、回滚恢复 sandbox |
| MODERATE | 15 | 多列KB schema、flow_directive、URL爬虫、per-item publish |
| MINOR | 8 | L0/L1目录分离、master scope、lint scope |

---

## Task 1: KB 文本 Chunking (CRITICAL #4)

**文件**: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_store.ex`

**问题**: upsert 存整个文本为一 chunk，大文本搜索精度差

**修复**: 添加 `chunk_text/1` 函数，按段落切分（max 600 chars, min 50 chars），每个 chunk 独立 upsert

```elixir
defp chunk_text(text) when is_binary(text) do
  text
  |> String.split(~r/\n\n+/, trim: true)
  |> Enum.flat_map(fn para ->
    if String.length(para) > 600 do
      # Split long paragraph by sentences
      para
      |> String.split(~r/(?<=[。！？\.\!\?])\s*/, trim: true)
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.join(&1, ""))
    else
      [para]
    end
  end)
  |> Enum.filter(&(String.length(&1) >= 50))
  |> Enum.map(&String.slice(&1, 0, 600))
end
```

修改 `ingest_file` 和 `fetch_url`：获取完整文本后调用 `chunk_text`，每个 chunk 单独 upsert。

---

## Task 2: Sandbox Diff 计算 (CRITICAL #16)

**文件**: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex`

**问题**: `record_file_change` 只计数，不计算实际 diff

**修复**: 添加 `compute_sandbox_diff/1` 函数，hash 对比 sandbox vs release 的关键文件

```elixir
def compute_sandbox_diff(tid) do
  sandbox = TenantRuntime.sandbox_path(tid)
  release = Path.join([TenantRuntime.release_path(tid), "_current"])

  items = [
    check_diff("souls/customer.md", sandbox, release),
    check_diff("slots/customer.yaml", sandbox, release),
    check_diff_skills("skills/customer", sandbox, release),
    check_diff_kb(tid, sandbox, release)
  ]
  |> Enum.filter(& &1)
  
  %{items: items, count: length(items)}
end

defp check_diff(rel_path, sandbox, release) do
  s = Path.join(sandbox, rel_path)
  r = Path.join(release, rel_path)
  s_hash = if File.exists?(s), do: hash_file(s), else: nil
  r_hash = if File.exists?(r), do: hash_file(r), else: nil
  if s_hash != r_hash, do: %{path: rel_path, changed: true}, else: nil
end

defp hash_file(path) do
  File.stream!(path, [], 2048)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)
end
```

---

## Task 3: Skill Frontmatter 解析 (CRITICAL #23)

**文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/skill_manager_live.ex`

**问题**: Skill 编辑器显示原始 markdown，无 frontmatter/body 分离

**修复**: 解析 `---\n...\n---` frontmatter，分开展示 metadata 和 body

```elixir
defp parse_skill_frontmatter(content) do
  case String.split(content, "---\n", parts: 3) do
    [_, fm, body] ->
      case YamlElixir.read_from_string(fm) do
        {:ok, meta} -> {meta, String.trim(body)}
        _ -> {%{}, content}
      end
    _ -> {%{}, content}
  end
end
```

SkillCard 组件增加 `description` 属性和 intent_trigger 显示。

---

## Task 4: 回滚恢复 Sandbox (CRITICAL #22)

**文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/version_timeline_live.ex`

**问题**: 回滚只翻转 symlink，不恢复 sandbox 文件

**修复**: 回滚时从 release 复制文件到 sandbox

```elixir
def handle_event("rollback", %{"version" => version}, socket) do
  tid = socket.assigns.tid
  release_path = TenantRuntime.release_path(tid)
  sandbox_path = TenantRuntime.sandbox_path(tid)
  
  # Copy release files to sandbox
  source = Path.join([release_path, version])
  ["souls", "slots", "skills", "kb", "config"]
  |> Enum.each(fn dir ->
    src = Path.join([source, dir])
    dst = Path.join([sandbox_path, dir])
    if File.exists?(src) do
      File.rm_rf!(dst)
      File.cp_r!(src, dst)
    end
  end)
  
  # Flip symlink
  current = Path.join([release_path, "_current"])
  File.rm!(current)
  File.ln_s!(source, current)
  
  {:noreply, assign(socket, current: version, flash_msg: "Rolled back to #{version}")}
end
```

---

## Task 5: PDF/XLSX 语义提取 (CRITICAL #5, #7)

**文件**: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_store.ex`

**问题**: PDF 全文截断 5000 chars, XLSX 纯文本拼接

**修复** (PDF): 改进 `extract_pdf_text` — 若 pdftotext 不可用，回退到 pypdf 命令行版本
**修复** (XLSX): 改进 `extract_xlsx_text` — 提取行列结构而非纯拼接

```elixir
# PDF: 每页独立 chunk
defp extract_pdf_text(path) do
  # Try pdftotext first (per-page output)
  case System.cmd("pdftotext", ["-layout", "-enc", "UTF-8", path, "-"], stderr_to_stdout: true) do
    {text, 0} when byte_size(text) > 50 ->
      text |> String.split("\f") |> Enum.map(&String.trim/1) |> Enum.join("\n\n")
    _ ->
      # Fallback: try using pypdf via python
      case System.cmd("python3", ["-c", "import pypdf;r=pypdf.PdfReader('#{path}');print('\\n\\n'.join(p.extract_text() or '' for p in r.pages))"], stderr_to_stdout: true) do
        {text, 0} -> text
        _ -> "PDF file: #{Path.basename(path)} (install pypdf: pip install pypdf)"
      end
  end
end

# XLSX: row-by-row with sheet names
defp extract_xlsx_text(path) do
  try do
    {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
    strings = extract_xlsx_strings(files)
    sheets = extract_xlsx_sheets(files, strings)
    sheets
    |> Enum.map(fn {name, rows} -> "[Sheet: #{name}]\n#{Enum.join(rows, "\n")}" end)
    |> Enum.join("\n\n")
  rescue
    _ -> "XLSX file: #{Path.basename(path)}"
  end
end
```

---

## Task 6: 异步 Ingest Jobs (CRITICAL #8)

**文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/kb_manager_live.ex`

**问题**: URL 抓取和文件上传同步阻塞 LiveView

**修复**: 使用 `Task.async` 异步执行，返回 polling 状态

```elixir
def handle_event("fetch_url", %{"url" => url}, socket) do
  kb_dir = socket.assigns.kb_dir
  tid = socket.assigns.tid
  
  task = Task.async(fn ->
    KbStore.fetch_url(kb_dir, url)
  end)
  
  {:noreply, assign(socket, ingest_task: task, url_flash: "抓取中...")}
end

def handle_info({ref, result}, socket) when ref == socket.assigns.ingest_task.ref do
  Process.demonitor(ref, [:flush])
  case result do
    {:ok, _} -> {:noreply, assign(socket, url_flash: "抓取完成", ingest_task: nil)}
    _ -> {:noreply, assign(socket, url_flash: "抓取失败", ingest_task: nil)}
  end
end
```

---

## Task 7: ETag 并发控制 (CRITICAL #11)

**文件**: SlotEditorLive, SoulEditorLive

**问题**: 无并发写保护，last write wins

**修复**: mount 时计算 ETag (SHA-256 hash of file content)，保存时 If-Match 检查

```elixir
# In mount:
etag = :crypto.hash(:sha256, raw_content) |> Base.encode16(case: :lower)

# In save handler:
current_etag = compute_etag(File.read!(path))
if current_etag != socket.assigns.etag do
  {:noreply, assign(socket, saved_flash: "⚠️ 文件已被他人修改，请刷新后重试")}
else
  File.write!(path, new_content)
  new_etag = compute_etag(new_content)
  {:noreply, assign(socket, content: new_content, etag: new_etag, saved_flash: "已保存")}
end
```

---

## 实施顺序

1. **Task 1** — KB chunking (最直接影响搜索质量)
2. **Task 2** — Sandbox diff (CR Dashboard 显示变更)
3. **Task 3** — Skill frontmatter (Skill 编辑改善)
4. **Task 4** — 回滚恢复 sandbox
5. **Task 5** — PDF/XLSX 语义提取
6. **Task 6** — 异步 ingest
7. **Task 7** — ETag

---

> 每个 Task 单独 commit。P0（前4个 task）今天完成。
