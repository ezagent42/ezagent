// LoomSaveTemplate — admin 顶栏 "Save as Template" 按钮(仅 loom session 渲染)。
// 点击 → 提示命名 → POST /loom/c/<ws>/<sid>/save-template 把当前 approved 页存为
// 可复用模板(后端 EzagentPluginLoom.SavedTemplates)。loom 自包含(走 /loom 端点),
// admin 只负责触发。
export const LoomSaveTemplate = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const ws = this.el.dataset.ws
      const sid = this.el.dataset.sid
      const token = this.el.dataset.token
      if (!ws || !sid || !token) return

      const name = window.prompt("把当前 Loom 页面存为模板，命名：")
      if (!name) return

      this.el.disabled = true
      try {
        const r = await fetch(`/loom/c/${ws}/${sid}/save-template`, {
          method: "POST",
          headers: {"content-type": "application/json"},
          body: JSON.stringify({name, token}),
        })
        const j = await r.json()
        if (j.ok) {
          window.alert(`已存为模板：${j.name}`)
        } else {
          window.alert(`存模板失败：${j.error || r.status}`)
        }
      } catch (e) {
        window.alert(`存模板出错：${e}`)
      } finally {
        this.el.disabled = false
      }
    })
  },
}
