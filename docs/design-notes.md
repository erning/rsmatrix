# Design Notes: Why the Implementation Diverges from the Original Plan

The original `docs/implementation-plan.md` was a faithful translation of `gomatrix`'s Go architecture into Rust idioms — goroutines became OS threads, Go channels became `crossbeam-channel`, and `tcell` became `crossterm`. During implementation, a fundamentally different architecture emerged that is simpler, faster, and more reusable. This document explains each divergence and its rationale.

---

## 1. Three-Layer Workspace (was: Single Crate)

**Plan**: A single crate with `src/main.rs`, `src/screen.rs`, `src/column.rs`, `src/stream.rs`, `src/charset.rs`, `src/types.rs`.

**Actual**: A Cargo workspace with three crates:

| Crate | Purpose | Dependencies |
|-------|---------|-------------|
| `rsmatrix-core` | Simulation engine (charset, grid, streams, columns) | `rand` only |
| `rsmatrix-cli` | Terminal UI (event loop, screen buffer, rendering) | `crossterm`, `clap`, `signal-hook`, `rsmatrix-core` |
| `rsmatrix-ffi` | C FFI for external consumers (Swift, etc.) | `rsmatrix-core` |

**Why this is better**: The core simulation has zero platform dependencies. Any frontend — terminal, macOS screensaver, Linux XScreenSaver, Windows SCR, WASM canvas — can drive the same `Simulation::tick()`. This directly enabled the macOS screensaver (Swift consuming `rsmatrix-ffi`) and the planned Linux/Windows screensavers. A single-crate design would have entangled terminal-specific code (crossterm, raw mode, alternate screen) with simulation logic, making reuse impossible without major refactoring.

---

## 2. Single-Threaded Event Loop (was: Thread-Per-Stream)

**Plan**: Six thread types mirroring Go's goroutine model:

- Main thread (1)
- Event Poller thread (1)
- Screen Flusher thread (1)
- Column Manager thread (1)
- Column Worker threads (1 per terminal column)
- Stream Worker threads (1 per active raindrop)

Coordination via `crossbeam-channel` `select!`, shared state via `Arc<Mutex<ScreenBuffer>>`, `Arc<RwLock<Sizes>>`, `Arc<AtomicU64>`.

**Actual**: A single `loop` in `main()`. `crossterm::event::poll(frame_duration)` serves as both the event listener and the frame timer. No threads participate in the simulation.

**Why this is better**:

- **No mutex contention**: The plan required every stream worker to lock the screen buffer on every tick. With hundreds of concurrent streams, this would cause significant lock contention. The single-threaded design has zero locking.
- **No deadlock risk**: Multiple mutexes (`ScreenBuffer`, `Sizes`, stream sets) with multiple threads is a classic deadlock setup. Eliminated entirely.
- **No thread coordination bugs**: Go's goroutines are cheap; Rust OS threads are not. Thread creation/destruction on every resize (stream workers, column workers) adds latency and fragility. The single-threaded model handles resize by simply truncating or extending a `Vec<Column>`.
- **Simpler code**: ~460 lines total (simulation.rs + main.rs + screen.rs) vs. the plan's estimated ~800+ lines across 6 files with channel wiring.
- **Fewer dependencies**: `crossbeam-channel` is no longer needed at all.

The Go version uses goroutines because they're nearly free (4 KB stack, M:N scheduler). Translating goroutines into OS threads (default 8 MB stack each) is the wrong abstraction mapping. The right translation is: goroutines with channels → a tick-based simulation loop.

---

## 3. Delta-Time Accumulator (was: Thread Sleep Timers)

**Plan**: Each stream worker thread uses `crossbeam_channel::select!` with a `default(Duration::from_millis(speed))` timeout as its tick timer. The screen flusher thread sleeps for the FPS interval between flushes.

**Actual**: Each `Stream` struct has an `accumulated_ms: u32` field. On each frame, `Simulation::tick(delta_ms)` adds the frame's delta time to every stream's accumulator. When `accumulated_ms >= speed_ms`, the stream advances one step and subtracts `speed_ms`.

```
// Accumulator pattern (actual)
stream.accumulated_ms += delta_ms;
while stream.accumulated_ms >= stream.speed_ms {
    stream.accumulated_ms -= stream.speed_ms;
    // advance head, advance tail
}
```

**Why this is better**:

- **Frame-rate independent**: The simulation produces identical visual results regardless of whether the host runs at 25 FPS or 60 FPS. Streams that are faster than the frame rate correctly advance multiple steps per frame.
- **No jitter**: OS thread scheduling is non-deterministic — a thread sleeping for 50ms might wake up after 51ms or 65ms depending on system load. The accumulator pattern eliminates this source of visual stutter.
- **Deterministic**: Given the same RNG seed and the same sequence of `tick(delta_ms)` calls, the simulation produces identical output. This makes testing trivial and future features (replay, recording) straightforward.
- **One timer instead of hundreds**: The plan needed one OS timer per stream. The accumulator pattern uses zero OS timers — just integer arithmetic.

---

## 4. Simulation as Pure Data (was: Threads with Channels)

**Plan**: `Stream` and `ColumnWorker` are autonomous threads communicating via channels:

```
// Plan: thread-based stream
pub struct Stream {
    stop_rx: Receiver<()>,
    new_stream_tx: Sender<()>,
    screen: Arc<Mutex<ScreenBuffer>>,
    sizes: Arc<RwLock<Sizes>>,
    stream_set: Arc<Mutex<HashSet<usize>>>,
    // ...
}
```

**Actual**: `Simulation` is a struct that owns all state. Streams and columns are plain data:

```
// Actual: data-driven stream
struct Stream {
    speed_ms: u32,
    length: i32,
    head_pos: i32,
    tail_pos: i32,
    head_done: bool,
    tail_signaled: bool,
    last_char: char,
    accumulated_ms: u32,
}
```

The `SpawnState` enum (`Idle` / `Delaying { remaining_ms }`) replaces the channel-based signaling between streams and column workers. Stream removal uses `Vec::retain_mut()` instead of `Arc<Mutex<HashSet<usize>>>`.

**Why this is better**:

- **Testable**: `Simulation::tick()` is a pure function of its inputs (delta time + RNG). Unit testing a thread-based architecture requires synchronization barriers, timeouts, and flaky assertions on timing.
- **Reusable via FFI**: The `Simulation` struct is exposed through `rsmatrix-ffi` as an opaque pointer with C functions (`rsmatrix_create`, `rsmatrix_tick`, `rsmatrix_get_grid`). A thread-based simulation cannot be driven by an external event loop (like macOS's `CADisplayLink` or a screensaver framework's timer).
- **No shared mutable state**: The plan required 4 types of shared state (`Arc<Mutex<_>>`, `Arc<RwLock<_>>`, `Arc<AtomicU64>`, `AtomicUsize`). The actual implementation has zero shared mutable state — the `Simulation` is exclusively owned by whoever calls `tick()`.

---

## 5. Reduced Dependencies (8 → 4 CLI, 1 core)

| Dependency | Plan | Actual | Reason for change |
|-----------|------|--------|-------------------|
| `crossterm` | 0.28 | 0.29 | Version bump |
| `clap` | 4 | 4.6 | Version bump |
| `rand` | 0.8 | 0.10 | Version bump |
| `signal-hook` | 0.3 | 0.4 | Version bump |
| `crossbeam-channel` | 0.5 | removed | No threads → no channels |
| `log` | 0.4 | removed | Debug logging not implemented |
| `simplelog` | 0.12 | removed | Debug logging not implemented |
| `dirs` | 6 | removed | No log file → no home dir lookup |

The core crate (`rsmatrix-core`) depends only on `rand`. This is critical for FFI consumers — a macOS screensaver linked against the core should not pull in terminal libraries.

---

## 6. Owned Screen Buffer (was: `Arc<Mutex<_>>`)

**Plan**: `Arc<Mutex<ScreenBuffer>>` shared between all stream worker threads (writers) and the flusher thread (reader).

**Actual**: `ScreenBuffer` is a local variable in `main()`, owned exclusively by the main loop. No `Arc`, no `Mutex`.

**Why this is better**: The plan's design locks the mutex for every `set_cell()` call (nanoseconds each, but hundreds of times per frame across all stream threads) and holds it for the entire `flush()` duration (milliseconds, iterating all dirty cells). This creates contention between the flusher and the stream workers. The single-threaded design writes all cells, then flushes once — no contention possible.

---

## 7. Flat Grid with `#[repr(C)]` (was: `Vec<Vec<Cell>>`)

**Plan**: `cells: Vec<Vec<Cell>>` — a vector of row vectors, each separately heap-allocated.

**Actual**: `cells: Vec<Cell>` — a single flat allocation, row-major order. `Cell` is `#[repr(C)]` with fields `(codepoint: u32, r: u8, g: u8, b: u8)`.

**Why this is better**:

- **Cache-friendly**: A single contiguous allocation vs. N separate heap allocations (one per row). Sequential iteration during `flush()` and `tick()` benefits from CPU cache prefetching.
- **FFI-passable**: `rsmatrix_get_grid()` returns a raw `*const Cell` pointer. The flat `#[repr(C)]` layout is directly readable by C and Swift without marshaling. A `Vec<Vec<Cell>>` cannot be passed across FFI boundaries.
- **Single allocation**: Resize is one `vec![Cell::blank(); w * h]` instead of allocating H separate row vectors.

---

## 8. FFI Layer (not in original plan)

The original plan had no concept of FFI or external consumers. The `rsmatrix-ffi` crate was added to enable the macOS screensaver and establishes the pattern for future platform integrations:

```c
// C API surface
Simulation* rsmatrix_create(uint32_t width, uint32_t height);
void        rsmatrix_destroy(Simulation* sim);
void        rsmatrix_tick(Simulation* sim, uint32_t delta_ms);
void        rsmatrix_resize(Simulation* sim, uint32_t width, uint32_t height);
const Cell* rsmatrix_get_grid(const Simulation* sim);
uint32_t    rsmatrix_grid_width(const Simulation* sim);
uint32_t    rsmatrix_grid_height(const Simulation* sim);
void        rsmatrix_set_charset(uint32_t mode);
```

This API is minimal and stateless from the caller's perspective — create, tick, read grid, destroy. Any platform with a C FFI can drive the simulation.

---

## Summary

The original plan was a correct 1:1 translation of Go idioms into Rust. The actual implementation recognized that Go's concurrency model (cheap goroutines + channels) doesn't map well to Rust's concurrency model (OS threads + ownership). Instead of fighting the language, the redesign embraced Rust's strengths: ownership (no shared mutable state), value types (flat data structures), and zero-cost abstractions (`#[repr(C)]` for FFI). The result is less code, fewer dependencies, better performance, and a reusable core that powers both the terminal app and platform screensavers.
