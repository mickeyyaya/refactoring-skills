---
name: python-review-patterns
description: Python-specific code review guide for AI reviewers. Covers mutable defaults, type hints, GIL and concurrency patterns, import anti-patterns, Pythonic idioms, and exception handling. Load alongside review-accuracy-calibration to calibrate confidence before posting Python findings.
---

# Python Code Review Patterns

## Overview

Python's design — dynamic typing, duck typing, mutable defaults, and the GIL — creates a class of bugs invisible to reviewers unfamiliar with the language. A reviewer applying general rules without Python context will generate false positives (flagging correct duck typing as a type error) and false negatives (missing the mutable default argument trap, which looks syntactically valid but is always wrong).

Load this skill when reviewing a Python PR, assigning severity to a Python-specific finding, or checking whether a flagged pattern is a real bug or a duck-typing false positive.

## Quick Reference

| Review Dimension | Severity | Primary Red Flag |
|-----------------|----------|-----------------|
| Mutable default argument | HIGH | `def f(x=[])` or `def f(x={})` |
| Mutable class attribute | HIGH | `class C: items = []` shared across instances |
| Missing type hints on public API | LOW | No annotations on public function signatures |
| Incomplete type hints (partial) | MEDIUM | Some args annotated, others not |
| `Optional` vs `X \| None` | NIT | Use `X \| None` in Python 3.10+; `Optional[X]` in 3.9- |
| GIL: CPU-bound in threads | HIGH | `threading.Thread` doing heavy computation |
| asyncio blocking call | HIGH | `time.sleep()` or sync I/O inside `async def` |
| Bare `except:` | MEDIUM | Catches `KeyboardInterrupt`, `SystemExit` |
| Exception swallowed silently | HIGH | `except Exception: pass` with no log |
| Star import | MEDIUM | `from module import *` in non-`__init__` context |
| Circular import | HIGH | Mutually importing modules at top level |
| `global` keyword | MEDIUM | Mutable shared state; HIGH under threading |
| `eval()`/`exec()` on user input | CRITICAL | Arbitrary code execution |
| `assert` in production logic | HIGH | Stripped by `-O`; never use for validation |
| Non-context-manager resource | MEDIUM | `f = open(...)` without `with` |

## Mutable Default Arguments

Python evaluates default argument values once at function definition time, not at call time. A mutable default (list, dict, set) is shared across all calls that omit the argument — always a bug.

```python
# WRONG — items persists across calls
def append_item(value, items=[]):
    items.append(value)
    return items

append_item(1)  # [1]
append_item(2)  # [1, 2] — not [2]
```

```python
# CORRECT — use None as sentinel
def append_item(value, items=None):
    if items is None:
        items = []
    items.append(value)
    return items
```

The same trap applies at class level: a mutable attribute in the class body is shared across all instances.

```python
# WRONG
class Cart:
    items = []          # shared across ALL instances
    def add(self, item):
        self.items.append(item)

# CORRECT
class Cart:
    def __init__(self):
        self.items = []  # per-instance
    def add(self, item):
        self.items.append(item)
```

**Severity:** HIGH (C3). Deterministic wrong behavior. Flag immediately.

## Type Hints and Annotations

### When to Require Type Hints

- Public API functions: require full annotations (params and return type)
- Internal helpers: LOW if missing; NIT if partially annotated
- Test files: NIT only

```python
# WRONG — partial annotation misleads callers
def process(data: list, threshold) -> None: ...

# CORRECT — fully annotated
def process(data: list[str], threshold: float) -> None: ...
```

### `Optional` vs `X | None`

```python
# Python 3.9 and earlier
from typing import Optional
def find_user(user_id: int) -> Optional[str]: ...

# Python 3.10+ — prefer X | None
def find_user(user_id: int) -> str | None: ...
```

### Protocol for Structural Typing

Use `Protocol` when a function accepts "any object with method X" — makes the contract explicit instead of relying on implicit duck typing.

```python
from typing import Protocol

class Saveable(Protocol):
    def save(self) -> None: ...

def persist(obj: Saveable) -> None:
    obj.save()
```

**Severity:** Missing `Protocol` on structural interfaces — LOW. Partial annotations — MEDIUM.

## GIL and Concurrency

The GIL prevents true parallel execution of Python bytecode across threads. The consequence:

- **I/O-bound work** — threading is fine; GIL releases during I/O syscalls
- **CPU-bound work** — threading gives no speedup; use `multiprocessing` or `ProcessPoolExecutor`
- **asyncio** — single-threaded cooperative multitasking; correct for high-concurrency I/O, wrong for CPU work

```python
# WRONG — threading for CPU-bound; GIL prevents parallel execution
threads = [threading.Thread(target=heavy_compute, args=(chunk,)) for chunk in data]

# CORRECT — multiprocessing bypasses the GIL
from concurrent.futures import ProcessPoolExecutor
with ProcessPoolExecutor() as pool:
    results = list(pool.map(heavy_compute, data))
```

```python
# WRONG — blocking call freezes the entire event loop
async def fetch_data():
    time.sleep(2)           # blocks all coroutines
    data = open("f").read() # sync I/O blocks event loop

# CORRECT
async def fetch_data():
    await asyncio.sleep(2)
    async with aiofiles.open("f") as f:
        data = await f.read()
```

**Severity:** CPU-bound work in threads — HIGH (C3). Blocking call in `async def` — HIGH (C3). Missing `asyncio.gather` for independent async calls — MEDIUM.

## Import Anti-Patterns

### Star Imports

`from module import *` pollutes the namespace, makes name origins untraceable, and can silently override local names. Flag as MEDIUM in application code (NIT in `__init__.py` that re-exports a public API).

```python
# WRONG
from os.path import *
from utils import *

# CORRECT
from os.path import join, exists, dirname
```

### Circular Imports

Modules that import each other at top level cause `ImportError` or partially-initialized module states. Restructure, or use `TYPE_CHECKING` for type-only imports.

```python
# WRONG — circular if services imports models
# models.py
from services import UserService

# CORRECT — type-only import
from __future__ import annotations
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from services import UserService
```

**Severity:** HIGH (C3). Indicates structural coupling causing runtime failures.

### Import Side Effects

Modules that perform I/O or mutate global state on import break test isolation and make module-load order significant.

```python
# WRONG — runs at import time
import psycopg2
conn = psycopg2.connect(DATABASE_URL)

# CORRECT — lazy initialization
_conn = None
def get_connection():
    global _conn
    if _conn is None:
        _conn = psycopg2.connect(DATABASE_URL)
    return _conn
```

**Severity:** MEDIUM (C3).

## Pythonic Idioms

### Comprehensions vs `map`/`filter`

```python
# WRONG — map with lambda; harder to read
result = list(map(lambda x: x * 2, numbers))
evens = list(filter(lambda x: x % 2 == 0, numbers))

# CORRECT
result = [x * 2 for x in numbers]
evens = [x for x in numbers if x % 2 == 0]
```

Exception: `map` with a named function is acceptable — `list(map(str, items))`.

### Generators for Large Datasets

```python
# WRONG — builds full list in memory
total = sum([item.price for item in large_catalog])

# CORRECT — generator; no intermediate list
total = sum(item.price for item in large_catalog)
```

**Severity:** MEDIUM if input is unbounded; NIT for small bounded data.

### Context Managers

Always use `with` for resources that need cleanup (files, locks, database connections).

```python
# WRONG — file not closed on exception
f = open("data.txt")
data = f.read()
f.close()

# CORRECT
with open("data.txt") as f:
    data = f.read()
```

**Severity:** MEDIUM (C3). Resource leak on exception is a real bug.

### Other Idioms

```python
# WRONG — manual indexing
for i in range(len(items)):
    process(i, items[i])

# CORRECT — enumerate
for i, item in enumerate(items):
    process(i, item)

# WRONG — old-style formatting in Python 3.6+ codebases
msg = "Hello, %s! You have %d messages." % (name, count)

# CORRECT — f-string
msg = f"Hello, {name}! You have {count} messages."
```

Flag over-clever one-liners that sacrifice readability as MEDIUM:

```python
# WRONG — too dense to review safely
result = {k: [v for v in vals if v > 0] for k, vals in data.items() if any(v > 0 for v in vals)}

# CORRECT — split into named steps
positive_vals = {k: [v for v in vals if v > 0] for k, vals in data.items()}
result = {k: v for k, v in positive_vals.items() if v}
```

## Exception Handling

### Bare `except:`

`except:` (no exception type) catches `KeyboardInterrupt`, `SystemExit`, and `GeneratorExit` — prevents interruption and hides bugs.

```python
# WRONG
try:
    process_data()
except:
    pass  # swallows KeyboardInterrupt, SystemExit

# CORRECT
try:
    process_data()
except (ValueError, TypeError) as exc:
    logger.error("Processing failed: %s", exc)
    raise
```

**Severity:** MEDIUM for bare `except:` that logs; HIGH for `except: pass`.

### Exception Chaining

```python
# WRONG — loses original traceback
try:
    value = config["key"]
except KeyError:
    raise ConfigError("Missing required key")

# CORRECT
try:
    value = config["key"]
except KeyError as exc:
    raise ConfigError("Missing required key") from exc
```

**Severity:** LOW (C3). Losing the original traceback impedes production debugging.

## Anti-Patterns

**`global` keyword abuse** — Creates mutable shared state; thread-unsafe without locks.
Severity: MEDIUM; HIGH if accessed across threads without synchronization.

**`eval()`/`exec()` with user input** — Allows arbitrary code execution.

```python
# CRITICAL — never do this
result = eval(request.POST["formula"])

# CORRECT — parse and validate with ast.parse before any evaluation
```

Severity: CRITICAL (C4). Direct code injection vulnerability.

**`assert` in production logic** — Stripped by `python -O`; never use for input validation or access control.

```python
# WRONG
assert amount > 0, "Amount must be positive"   # removed with -O

# CORRECT
if amount <= 0:
    raise ValueError(f"Amount must be positive, got {amount}")
```

Severity: HIGH (C3) for security/data-integrity assertions; MEDIUM for general validation.

**Hardcoded paths** — Use `pathlib` and environment-based configuration.
Severity: MEDIUM in application code; LOW in scripts or dev tooling.

## Cross-References

- `review-accuracy-calibration` — Apply confidence scoring (C1-C4) before posting any finding from this guide. Python's duck typing raises false positive risk; calibrate before flagging missing type hints.
- `error-handling-patterns` — Covers retry logic, circuit breakers, and error propagation strategies; complements the Exception Handling section.
- `security-patterns-code-review` — `eval()`/`exec()` findings go through the security checklist; treat as injection vulnerabilities.
- `concurrency-patterns` — GIL limitations and asyncio patterns cross-reference with language-agnostic concurrency review guidance.
