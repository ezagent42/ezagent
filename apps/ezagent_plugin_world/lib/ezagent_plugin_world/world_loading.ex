defmodule EzagentPluginWorld.WorldLoading do
  @moduledoc false

  use Phoenix.Component

  @doc false
  def shell(assigns) do
    ~H"""
    <div
      data-world-loading="shell-skeleton"
      role="status"
      aria-live="polite"
      aria-busy="true"
      class="min-h-screen bg-background text-foreground"
    >
      <span class="sr-only">Loading world</span>
      <div data-world-loading-progress class="h-0.5 overflow-hidden bg-border">
        <div class="h-full w-2/5 rounded-[999px] bg-primary motion-safe:animate-pulse motion-reduce:animate-none">
        </div>
      </div>

      <div
        aria-hidden="true"
        class="grid min-h-[calc(100vh-2px)] grid-rows-[auto_minmax(0,1fr)]"
      >
        <header class="grid grid-cols-1 items-center gap-3 border-b border-border bg-card px-3 py-2 shadow-sm sm:grid-cols-[250px_minmax(260px,1fr)_auto] sm:px-3.5 sm:py-2">
          <div class="flex min-w-0 items-center gap-2.5">
            <div class="grid h-7 w-7 shrink-0 place-items-center rounded-[7px] border-2 border-primary bg-primary/10">
              <div class="h-2.5 w-3.5 rounded-[3px] bg-primary"></div>
            </div>
            <div class="h-8 w-44 max-w-[60vw] rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
          </div>

          <div class="grid min-w-0 grid-cols-3 gap-1 rounded-[10px] border border-border bg-muted p-[3px] sm:justify-self-center">
            <div class="h-7 rounded-[7px] bg-card shadow-sm motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
            <div class="h-7 rounded-[7px] bg-card/60 motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
            <div class="h-7 rounded-[7px] bg-card/60 motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
          </div>

          <div class="flex min-w-0 justify-end gap-2">
            <div class="h-8 w-24 rounded-[8px] bg-primary/15 motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
            <div class="h-8 w-8 rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
            </div>
          </div>
        </header>

        <div class="grid min-h-0 grid-cols-1 gap-3 p-3 sm:p-4 lg:grid-cols-[276px_minmax(430px,1fr)_260px]">
          <section
            data-world-loading-panel="sessions"
            class="hidden min-h-0 border border-border bg-card lg:flex lg:flex-col"
          >
            <div class="border-b border-border p-3">
              <div class="h-4 w-28 rounded-[4px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="mt-2 h-8 rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>
            <div class="grid gap-2 p-2">
              <div class="h-16 rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="h-16 rounded-[8px] bg-muted/70 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="h-16 rounded-[8px] bg-muted/70 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>
          </section>

          <section
            data-world-loading-panel="conversation"
            class="grid min-h-[520px] grid-rows-[auto_minmax(0,1fr)_auto] border border-border bg-card"
          >
            <div class="flex items-center justify-between gap-3 border-b border-border p-3">
              <div class="min-w-0 flex-1">
                <div class="h-4 w-40 rounded-[4px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
                </div>
                <div class="mt-2 h-3 w-56 max-w-full rounded-[4px] bg-muted/70 motion-safe:animate-pulse motion-reduce:animate-none">
                </div>
              </div>
              <div class="h-8 w-20 rounded-[8px] bg-primary/15 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>

            <div class="min-h-0 space-y-3 overflow-hidden p-4">
              <div class="h-16 max-w-[78%] rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="ml-auto h-14 max-w-[68%] rounded-[8px] bg-primary/15 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="h-20 max-w-[84%] rounded-[8px] bg-muted/80 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="ml-auto h-12 max-w-[54%] rounded-[8px] bg-primary/10 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>

            <div class="border-t border-border p-3">
              <div class="h-12 rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>
          </section>

          <section
            data-world-loading-panel="context"
            class="hidden min-h-0 border border-border bg-card lg:flex lg:flex-col"
          >
            <div class="border-b border-border p-3">
              <div class="h-4 w-32 rounded-[4px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="mt-2 h-3 w-24 rounded-[4px] bg-muted/70 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>
            <div class="grid gap-3 p-3">
              <div class="h-24 rounded-[8px] bg-muted motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="h-20 rounded-[8px] bg-muted/75 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
              <div class="h-28 rounded-[8px] bg-muted/75 motion-safe:animate-pulse motion-reduce:animate-none">
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
