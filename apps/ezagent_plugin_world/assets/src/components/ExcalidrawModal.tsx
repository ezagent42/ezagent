import {lazy, Suspense, useState} from "react"

import {restoreElements} from "@excalidraw/excalidraw"
import type {ExcalidrawImperativeAPI, ExcalidrawInitialDataState} from "@excalidraw/excalidraw/types"
import "@excalidraw/excalidraw/index.css"

import {Button} from "./ui/primitives"

// 懒加载：excalidraw 包很大(~2MB)，只在点开编辑器时才下载，不进主 bundle。
const Excalidraw = lazy(() =>
  import("@excalidraw/excalidraw").then((m) => ({default: m.Excalidraw})),
)

type ExcalidrawAPI = ExcalidrawImperativeAPI | null

/**
 * 内嵌 excalidraw 编辑器（弹窗）。
 * - 真相源 = kanban 节点附件：画完保存 = 把 scene 的 elements 序列化成 JSON 存进 artifact.content。
 * - 只存 elements（不存完整 appState）以稳进 8KB inline 上限。
 * - readOnly 时 viewModeEnabled，纯查看不可编辑。
 */
export function ExcalidrawModal({
  initial,
  readOnly = false,
  onSave,
  onClose,
}: {
  initial?: string | null
  readOnly?: boolean
  onSave?: (sceneJson: string) => void
  onClose: () => void
}) {
  const [api, setApi] = useState<ExcalidrawAPI>(null)
  const [tooBig, setTooBig] = useState(false)

  let initialData: ExcalidrawInitialDataState | undefined
  try {
    if (initial) {
      const parsed = JSON.parse(initial)
      if (Array.isArray(parsed?.elements)) initialData = {elements: restoreElements(parsed.elements, null)}
    }
  } catch {
    initialData = undefined
  }

  const save = () => {
    if (!api || !onSave) return
    const json = JSON.stringify({type: "excalidraw", elements: api.getSceneElements()})
    // 64KB inline 上限(后端 @artifact_content_limit 同值)：超了提示、不保存(画还在,不丢)
    if (new Blob([json]).size > 65536) {
      setTooBig(true)
      return
    }
    onSave(json)
    onClose()
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black/50 p-4 sm:p-6">
      <div className="flex h-full flex-col overflow-hidden rounded-md bg-card shadow-lg">
        <div className="flex items-center justify-between border-b border-border px-3 py-2">
          <span className="text-sm font-medium text-foreground">
            {readOnly ? "查看线框/草图" : "画线框/草图（excalidraw）"}
          </span>
          <div className="flex items-center gap-2">
            {tooBig && <span className="text-xs text-destructive">图太大(&gt;64KB)，请简化或改用上传文件（你的画还在，没丢）</span>}
            {!readOnly && (
              <Button type="button" size="sm" onClick={save}>
                保存到节点
              </Button>
            )}
            <Button type="button" size="sm" variant="secondary" onClick={onClose}>
              关闭
            </Button>
          </div>
        </div>
        {/* relative + absolute-inset 给 excalidraw 一个**确定尺寸**的父级——否则它塌成 0 高度，
            既画不了也存不了(api 拿不到 scene)。这是"比例不对/没法画/没法保存"的根因。 */}
        <div className="relative min-h-0 flex-1">
          <div style={{position: "absolute", inset: 0}}>
            <Suspense fallback={<div className="p-6 text-sm text-muted-foreground">加载画板中…</div>}>
              <Excalidraw
                excalidrawAPI={(nextApi) => setApi(nextApi)}
                initialData={initialData}
                viewModeEnabled={readOnly}
              />
            </Suspense>
          </div>
        </div>
      </div>
    </div>
  )
}
