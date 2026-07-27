# Hello–Kanban product closeout evidence

Recorded against the disposable local stack at `http://127.0.0.1:10052` with
an independent PostgreSQL database. The colleague-facing service on port 10042
was not used or modified.

## Recording A — live board reflux

`hello-kanban-live-board-reflux.webm` demonstrates:

1. the Hello product entry;
2. an honest delegation receipt labelled as a non-live snapshot;
3. the receipt CTA opening the concrete World Kanban board;
4. claiming the delegated task and changing its status to `doing`;
5. reloading the board and observing the persisted `doing` state; and
6. returning to Hello, where the receipt remains explicitly a snapshot.

## Recording B — concierge navigation

`hello-concierge-navigation.webm` demonstrates an authenticated owner entering
`看看团队`. The concierge response executes the approved navigation action and
the rendered page visibly switches to the Team surface, including 林懿伦.

Both recordings use a locked 1280×720 viewport. The recorder fails if the
browser viewport drifts or if the expected live UI outcome is not visible.
