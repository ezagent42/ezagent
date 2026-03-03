"""EZAgent42 HTTP API server.

FastAPI application wrapping the Rust Engine via PyO3 bindings.

NOTE: All endpoint functions are synchronous (``def``, not ``async def``)
because ``PyEngine`` is a PyO3 ``unsendable`` class -- it must only be
accessed from the OS thread that created it.  Synchronous FastAPI
endpoints are dispatched to a worker threadpool; we store the engine in
a ``threading.local()`` so each worker thread lazily creates its own
instance and never touches another thread's ``PyEngine``.

For single-worker / test scenarios the thread-local effectively acts
as a singleton.

Engine versioning
~~~~~~~~~~~~~~~~~
A global ``_engine_version`` counter is bumped every time the factory or
reset function is called.  Each thread-local slot records which version
it was created at; ``get_engine`` compares the two and re-creates the
engine when they diverge.  This lets test fixtures on the *test* thread
invalidate the portal thread's cached engine without directly touching
the thread-local from another thread.
"""

from __future__ import annotations

import threading
from typing import Callable, Optional

from fastapi import Depends, FastAPI, HTTPException

from ezagent._native import PyEngine

# ---------------------------------------------------------------------------
# Engine management -- thread-local storage for unsendable PyO3 class
# ---------------------------------------------------------------------------

_local = threading.local()

# Optional factory hook -- tests can override this to inject a pre-
# configured engine (e.g. one with identity already initialised).
_engine_factory: Optional[Callable[[], PyEngine]] = None

# Monotonically increasing version; bumped on reset / factory change.
_engine_version: int = 0


def _default_engine_factory() -> PyEngine:
    """Create a bare PyEngine (identity uninitialised)."""
    return PyEngine()


def get_engine() -> PyEngine:
    """FastAPI dependency: per-thread engine, lazily created.

    The engine is recreated when the global version has advanced past
    the thread-local version (i.e. after a ``reset_engine`` or
    ``set_engine_factory`` call from any thread).
    """
    local_ver: int = getattr(_local, "engine_version", -1)
    if local_ver != _engine_version:
        # Version mismatch -- need a fresh engine on *this* thread.
        _local.engine = None

    engine: Optional[PyEngine] = getattr(_local, "engine", None)
    if engine is None:
        factory = _engine_factory or _default_engine_factory
        engine = factory()
        _local.engine = engine
        _local.engine_version = _engine_version
    return engine


def set_engine_factory(factory: Optional[Callable[[], PyEngine]]) -> None:
    """Override the factory used to create new ``PyEngine`` instances.

    Bumps the engine version so that worker threads will lazily recreate
    their engines using the new factory on the next request.

    Pass ``None`` to restore the default factory.  Primarily used by
    tests that need engines with pre-configured identity.
    """
    global _engine_factory, _engine_version
    _engine_factory = factory
    _engine_version += 1


def reset_engine() -> None:
    """Invalidate engines across all threads.

    Bumps the global version so every thread will recreate its engine
    on the next call to ``get_engine``.  The old engine on each thread
    is dropped lazily (on the same thread that created it) the next
    time ``get_engine`` is called, preserving PyO3 thread-affinity.
    """
    global _engine_version
    _engine_version += 1


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="ezagent",
    version="0.1.0",
    description="EZAgent42 HTTP API",
)


@app.get("/api/status")
def get_status(engine: PyEngine = Depends(get_engine)):
    """Health check and engine status."""
    initialized, datatypes = engine.status()
    return {
        "status": "ok",
        "identity_initialized": initialized,
        "registered_datatypes": datatypes,
    }


@app.get("/api/identity")
def get_identity(engine: PyEngine = Depends(get_engine)):
    """Return current identity information."""
    try:
        entity_id = engine.identity_whoami()
    except RuntimeError as e:
        raise HTTPException(status_code=401, detail={
            "error": {"code": "UNAUTHORIZED", "message": str(e)}
        })
    return {"entity_id": entity_id}
