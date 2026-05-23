# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=1.26",
#   "sympy>=1.12",
# ]
# ///
"""
np_compute_server.py — the Python subprocess backing the np-agent
Ezagent plugin.

Spawned by `Ezagent.PluginNp.Template.NpAgent.instantiate/3` via
`Ezagent.Domain.Python.start_subprocess/1`. One subprocess per
NpAgent Kind (see plugin Application moduledoc for why per-agent +
not shared).

## Registered JSON-RPC methods

  - `compute(expr: str) -> {result: number | str}`
      Evaluate a numeric numpy expression safely. The input is parsed
      via `sympy.sympify` first (sympy understands numpy-style
      arithmetic plus all common functions); the result is then
      evaluated to a numeric value via `.evalf()` and coerced to a
      Python int / float / str.

  - `compute_latex(expr: str) -> {result: number | str}`
      Parse LaTeX via `sympy.parsing.latex.parse_latex` then evaluate.
      Useful for the curl→np leg of the comprehensive e2e (the curl
      agent emits a LaTeX expression that np evaluates).

  - `ping() -> {ok: true}` — health check.

## Expression safety — NO raw eval()

The single non-negotiable invariant: a malicious sender may not
execute arbitrary Python. We MUST refuse `eval()` and `exec()` as
implementation tools. Concrete defenses:

  - `compute` route: input → `sympy.sympify(expr)` (sympy's parser
    builds a symbolic expression tree; it accepts only mathematical
    syntax — names that resolve to known symbolic objects, operators,
    function calls into a whitelisted namespace). We pass an EXPLICIT
    `locals` dict containing only safe math symbols (`pi`, `e`, `sin`,
    `cos`, `exp`, `log`, `sqrt`, `Symbol`, …). No `__builtins__`, no
    `os`, no `subprocess`. The result is `.evalf()` then coerced via
    `_to_python_number`.

  - `compute_latex` route: input → `parse_latex(expr)` (sympy's LaTeX
    parser is also pure-symbolic; no eval).

  - Input length cap (`MAX_INPUT_LEN`) to prevent pathological inputs
    from exhausting sympy.

  - Per-call wall-clock timeout is enforced on the Elixir side
    (`Domain.Python.call/4` with `:rpc_timeout`); the Python script
    does not enforce its own timer (sympy's `.evalf()` is typically
    fast; pathological inputs are caught by the Elixir timeout +
    `:subprocess_unhealthy` tear-down).

  - Result coercion via `_to_python_number` rejects any non-numeric /
    non-string output — sympy `Symbol` or unevaluated expressions
    yield `str(expr)` (the user sees the canonical algebraic form).

## What a malicious sender CAN'T do

  - `compute("__import__('os').system('rm -rf /')")` — sympify raises
    `SympifyError`; the call returns `RpcError(-32602, ...)`. No
    process side effect.
  - `compute("open('/etc/passwd').read()")` — `open` is not in the
    locals dict; sympify treats `open` as an unknown symbol → raises
    `SympifyError` because the result has free symbols the caller
    didn't ask for. (Defensive: even if it didn't raise, the symbol
    has no callable binding — sympify wouldn't invoke a Python
    function on it.)

## What a malicious sender CAN do

  - Send `compute("(2**1000000)**1000000")` — sympy will spend a long
    time computing this; the Elixir timeout (`Domain.Python.call/4`
    default 10s) fires and the subprocess is torn down per
    `Ezagent.Domain.Python.Server` SPEC §3.3.1. Fail-safe.
"""
from __future__ import annotations

import os
import sys

# Required by SPEC §6.3: Domain.Python sets EZAGENT_PYTHON_LIB_DIR
# pointing at apps/ezagent_domain_python/priv/python/.
sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run, log, RpcError  # noqa: E402

# Deferred imports (heavy): only imported once the script is alive +
# uv has installed deps.
import numpy as np  # noqa: E402
import sympy  # noqa: E402
from sympy.parsing.latex import parse_latex  # noqa: E402
from sympy.parsing.sympy_parser import parse_expr  # noqa: E402

# --- input safety knobs ---------------------------------------------------

MAX_INPUT_LEN = 4096

# Explicit whitelist of names sympy.parse_expr may resolve.
# DELIBERATELY EXCLUDES: open, exec, eval, __import__, os, subprocess,
# sys, getattr, setattr, anything that touches the filesystem or
# process. parse_expr never resolves names against globals() so even
# the absence of __builtins__ from `locals` doesn't expose them.
_SAFE_NAMES = {
    "pi": sympy.pi,
    "E": sympy.E,
    "e": sympy.E,
    "I": sympy.I,
    "oo": sympy.oo,
    "Inf": sympy.oo,
    "Infinity": sympy.oo,
    "Rational": sympy.Rational,
    "Symbol": sympy.Symbol,
    "Integer": sympy.Integer,
    "Float": sympy.Float,
    "sin": sympy.sin,
    "cos": sympy.cos,
    "tan": sympy.tan,
    "asin": sympy.asin,
    "acos": sympy.acos,
    "atan": sympy.atan,
    "exp": sympy.exp,
    "log": sympy.log,
    "ln": sympy.log,
    "sqrt": sympy.sqrt,
    "abs": sympy.Abs,
    "Abs": sympy.Abs,
    "floor": sympy.floor,
    "ceil": sympy.ceiling,
    "ceiling": sympy.ceiling,
    "factorial": sympy.factorial,
    # Integration / differentiation (LaTeX results often produce
    # these; safe — sympy expressions, not Python ops).
    "integrate": sympy.integrate,
    "diff": sympy.diff,
    "Sum": sympy.Sum,
    "Product": sympy.Product,
    "Integral": sympy.Integral,
    "Derivative": sympy.Derivative,
}


# --- helpers --------------------------------------------------------------


def _check_input_len(expr: str) -> None:
    if not isinstance(expr, str):
        raise RpcError(-32602, f"expr must be a string, got {type(expr).__name__}")
    if len(expr) == 0:
        raise RpcError(-32602, "expr must be non-empty")
    if len(expr) > MAX_INPUT_LEN:
        raise RpcError(
            -32602,
            f"expr exceeds {MAX_INPUT_LEN} chars (len={len(expr)}); reject to bound parser cost",
        )


def _to_python_number(value):
    """Coerce a sympy result to a JSON-serializable Python value.

    - Numeric → int (when integral) or float
    - Symbolic / non-numeric → canonical string form
    - numpy scalars → Python int/float via .item()
    """
    # numpy scalar?
    if hasattr(value, "item") and not isinstance(value, (bytes, str)):
        try:
            v = value.item()
            return _to_python_number(v)
        except Exception:  # noqa: BLE001
            pass

    if isinstance(value, (int, float)):
        return value

    if isinstance(value, complex):
        # Complex → string canonical form (JSON can't represent complex).
        return str(value)

    # numpy array?
    if isinstance(value, np.ndarray):
        return value.tolist()

    # sympy expression?
    if isinstance(value, sympy.Expr):
        try:
            v = value.evalf()
        except Exception:  # noqa: BLE001
            return str(value)

        # Try integer first (Allen's `2+2` should be `4`, not `4.0`).
        try:
            if v.is_integer:
                return int(v)
        except Exception:  # noqa: BLE001
            pass

        try:
            return float(v)
        except (TypeError, ValueError):
            # Free symbols / unevaluated → canonical string form.
            return str(value)

    if isinstance(value, list):
        return [_to_python_number(x) for x in value]

    if isinstance(value, tuple):
        return [_to_python_number(x) for x in value]

    # Unknown — fall back to str (the human will see it; JSON-safe).
    return str(value)


# --- registered methods ---------------------------------------------------


@method("ping")
def ping(_params):
    return {"ok": True}


@method("compute")
def compute(params):
    """Evaluate a numeric / symbolic expression via sympy.parse_expr.

    Safety:
      * input length cap (MAX_INPUT_LEN)
      * parse_expr with an EXPLICIT local_dict containing only
        whitelisted math symbols
      * NO __builtins__ exposed (parse_expr does not consult globals
        for name resolution)
      * NEVER calls eval() / exec()
    """
    expr = params.get("expr")
    _check_input_len(expr)

    try:
        parsed = parse_expr(expr, local_dict=_SAFE_NAMES, evaluate=True)
    except (SyntaxError, TypeError, ValueError) as e:
        raise RpcError(-32602, f"parse error: {type(e).__name__}: {e}")
    except Exception as e:  # noqa: BLE001
        # sympy's SympifyError + a few others all derive from Exception;
        # surface as -32602 (invalid params) with the message.
        raise RpcError(-32602, f"parse rejected: {type(e).__name__}: {e}")

    try:
        result = _to_python_number(parsed)
    except Exception as e:  # noqa: BLE001
        raise RpcError(-32603, f"result coercion failed: {type(e).__name__}: {e}")

    log("info", "compute ok", expr=expr, result_kind=type(result).__name__)
    return {"result": result}


@method("compute_latex")
def compute_latex(params):
    """Parse a LaTeX expression with sympy's parse_latex, then evaluate.

    Same safety profile as `compute` — parse_latex builds a symbolic
    tree from LaTeX syntax; no eval() involved.
    """
    expr = params.get("expr")
    _check_input_len(expr)

    try:
        parsed = parse_latex(expr)
    except Exception as e:  # noqa: BLE001
        raise RpcError(-32602, f"latex parse rejected: {type(e).__name__}: {e}")

    try:
        result = _to_python_number(parsed)
    except Exception as e:  # noqa: BLE001
        raise RpcError(-32603, f"result coercion failed: {type(e).__name__}: {e}")

    log("info", "compute_latex ok", expr=expr, result_kind=type(result).__name__)
    return {"result": result}


if __name__ == "__main__":
    run()
