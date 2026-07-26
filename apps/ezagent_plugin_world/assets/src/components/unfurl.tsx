import type {ComponentType} from "react"

import {pluginUnfurlRenderers} from "../generated/plugin-page-renderers"

// World 通用「链接 unfurl 气泡」机制（飞书式）——chat 消息渲染的注册式扩展点：
// 插件在 `pages/0` 的 `:unfurl` 字段声明一个链接模式（pattern）+ 气泡组件
// （renderer），消息文本命中模式时不显示裸链接、渲成该插件的气泡（点击动作由
// 组件自带，走 world:dispatch）。与 `plugin-page-renderers` manifest 同一姿势：
// 前端静态注册表 + 显式 import（Vite 静态打包），零动态加载、零 world→plugin 硬编码。
//
// 类型都定义在本模块（world 通用），生成的 manifest 只 `import type` 它们——
// 单向 type 依赖 + 单向 value 依赖（本模块 import manifest 的 pluginUnfurlRenderers
// 值），无运行时循环。

// 气泡组件运行时上下文（world 注入）。
export type UnfurlContext = {
  // 当前会话 URI（气泡可用作点击动作的会话上下文）
  sessionUri: string
  // 该消息是否是查看者自己发的（气泡配色可能要适配）
  mine: boolean
  // world:dispatch 通道（气泡点击动作走 in-app dispatch，不整屏跳转）
  dispatch?: (action: string, args: Record<string, unknown>) => void
}

// 插件 unfurl 气泡组件的标准 props 契约。
export type UnfurlBubbleProps = {
  // 命中的链接原文
  url: string
  // 去掉链接后 trim 的剩余文本（作气泡标题/说明；可为空串）
  rest: string
  ctx: UnfurlContext
}

// 生成的 manifest 用它标注 `pluginUnfurlRenderers` 数组（`import type` 回本模块）。
export type UnfurlRendererEntry = {
  id: string
  // 匹配消息文本中链接的模式（第一个命中即选中该条目）
  pattern: RegExp
  component: ComponentType<UnfurlBubbleProps>
}

export type UnfurlMatch = {
  entry: UnfurlRendererEntry
  url: string
  rest: string
}

// 消息文本 → 第一个命中的 unfurl 条目。rest = 去掉链接本身后 trim 的剩余文本。
// 空注册表（无插件声明 unfurl）→ 恒返回 null（行为与无 unfurl 完全一致）。
export function matchUnfurl(text: string): UnfurlMatch | null {
  for (const entry of pluginUnfurlRenderers) {
    const m = text.match(entry.pattern)
    if (m && m.index !== undefined) {
      const rest = (text.slice(0, m.index) + text.slice(m.index + m[0].length)).trim()
      return {entry, url: m[0], rest}
    }
  }
  return null
}
