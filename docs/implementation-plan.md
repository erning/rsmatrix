# rsmatrix: Rust Implementation Plan

## Context

This project implements a Matrix digital rain terminal effect in Rust, based on the product requirements in `docs/requirements.md`. An existing Go reference implementation exists in `gomatrix/`. The Rust version (`rsmatrix`) faithfully reproduces the same visual effect while using a fundamentally different architecture — a single-threaded, tick-based simulation engine separated from the terminal frontend.

For the rationale behind each architectural divergence from the Go original, see `docs/design-notes.md`.

---

## 1. Dependencies

### Workspace root `Cargo.toml`

```toml
[workspace]
members = ["rsmatrix-core", "rsmatrix-ffi", "rsmatrix-cli", "screensavers/linux", "screensavers/windows"]
resolver = "2"
default-members = ["rsmatrix-cli"]

[workspace.dependencies]
rsmatrix-core = { path = "rsmatrix-core" }
rand = "0.10"
clap = { version = "4.6", features = ["derive"] }
crossterm = "0.29"
signal-hook = "0.4"

[profile.release]
opt-level = 3
strip = true
lto = true
```

### Per-crate dependencies

| Crate | Dependencies | Purpose |
|-------|-------------|---------|
| `rsmatrix-core` | `rand` | Simulation engine — character sets, grid, streams, columns |
| `rsmatrix-cli` | `crossterm`, `clap`, `signal-hook`, `rsmatrix-core` | Terminal frontend — event loop, screen buffer, rendering |
| `rsmatrix-ffi` | `rsmatrix-core` | C FFI for Swift/external consumers |

**Rationale**:
- `crossterm` over `ratatui`: we need direct cell-level rendering, not widgets. crossterm is the closest analog to Go's tcell.
- No `crossbeam-channel`: the single-threaded design eliminates the need for multi-producer multi-consumer channels.
- No `log`/`simplelog`/`dirs`: debug logging to `~/.gomatrix-log` is not implemented; not needed for production use.
- No async runtime — a synchronous event loop with `crossterm::event::poll()` is sufficient.

---

## 2. Project Structure

```
rsmatrix/
├── Cargo.toml              # Workspace root
├── Makefile                 # macOS screensaver build
├── rsmatrix-core/
│   └── src/
│       ├── lib.rs
│       ├── charset.rs       # Character set definitions and atomic switching
│       ├── simulation.rs    # Tick-based simulation engine (grid, columns, streams)
│       └── types.rs         # Shared types (Sizes)
├── rsmatrix-cli/
│   └── src/
│       ├── main.rs          # Entry point, CLI, terminal init, event loop
│       └── screen.rs        # ScreenBuffer: dirty-cell tracking and flushing
├── rsmatrix-ffi/
│   └── src/
│       └── lib.rs           # C FFI functions wrapping Simulation
└── screensavers/
    ├── macos/               # Swift ScreenSaver bundle consuming rsmatrix-ffi
    ├── linux/               # Planned: XScreenSaver module
    └── windows/             # Planned: Windows SCR screensaver
```

---

## 3. Data Types

### 3.1 `rsmatrix-core/src/charset.rs` — Character Sets

Three character sets as static slices:

- `HALF_WIDTH_KANA: &[char]` — 63 chars, U+FF61 through U+FF9F
- `ALPHA_NUMERICS: &[char]` — 62 chars, A-Z, a-z, 0-9
- Combined charset — built lazily via `OnceLock` on first access (125 chars)

Global `AtomicUsize` stores the active charset index:

| Index | Constant | Character Set |
|-------|----------|---------------|
| 0 | `CHARSET_COMBINED` | Katakana + ASCII (125) |
| 1 | `CHARSET_ASCII` | ASCII only (62) |
| 2 | `CHARSET_KANA` | Katakana only (63) |

Public API:
- `set_charset(index: usize)` — atomically updates the active index
- `get_charset() -> &'static [char]` — returns the active charset slice
- `random_char(rng: &mut impl RngExt) -> char` — picks uniformly from active charset

Lock-free. Called by the simulation on every stream tick.

### 3.2 `rsmatrix-core/src/simulation.rs` — Simulation Engine

```rust
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Cell {
    pub codepoint: u32,    // Unicode codepoint
    pub r: u8, pub g: u8, pub b: u8,  // RGB color
}

struct Stream {
    speed_ms: u32,         // milliseconds per tick [30, 139]
    length: i32,           // visible chars before tail starts [10, 17]
    head_pos: i32,         // current head y-position (signed for first-tick row -1)
    tail_pos: i32,
    head_done: bool,
    tail_signaled: bool,   // has this stream triggered a new-stream signal?
    last_char: char,       // previous head char (for mid-stream re-render)
    accumulated_ms: u32,   // delta-time accumulator
}

enum SpawnState {
    Idle,                          // waiting for tail signal
    Delaying { remaining_ms: i32 }, // counting down spawn delay
}

struct Column {
    streams: Vec<Stream>,
    spawn_state: SpawnState,
}

pub struct Simulation {
    width: u32,
    height: u32,
    columns: Vec<Column>,
    grid: Vec<Cell>,       // flat, row-major, #[repr(C)]-compatible
}
```

`Cell` is `#[repr(C)]` to enable direct FFI access from C/Swift.

### 3.3 `rsmatrix-cli/src/screen.rs` — Screen Buffer

```rust
struct Cell {
    ch: char,
    fg: Color,       // crossterm::style::Color
    bg: Color,
    dirty: bool,
}

pub struct ScreenBuffer {
    cells: Vec<Cell>,   // flat, row-major
    width: u16,
    height: u16,
    full_redraw: bool,
}
```

Methods:
- `new(width, height)` — allocate grid, all cells = space / RGB(0,0,0) / RGB(0,0,0)
- `set_cell(col, row, fg, bg, ch)` — bounds-checked (silently ignores out-of-bounds), marks cell dirty
- `clear()` — fill all cells with space/black/black, mark dirty, set full_redraw
- `request_full_redraw()` — forces full repaint on next flush
- `flush(stdout)` — iterate cells, write only dirty ones via `crossterm::queue!(MoveTo, SetForegroundColor, SetBackgroundColor, Print)`, then `stdout.flush()`
- `resize(width, height)` — reallocate grid, set full_redraw

No `Arc`, no `Mutex` — the buffer is owned by the main loop.

---

## 4. Architecture: Single-Threaded Event Loop

The entire application runs in a single thread. `crossterm::event::poll(frame_duration)` serves as both the input event listener and the frame timer.

```
loop {
    poll(frame_duration)  // blocks until input arrives or frame_duration elapses
    handle input events   // quit, charset switch, FPS adjust, resize
    check SIGINT flag     // Arc<AtomicBool> set by signal-hook
    compute delta_ms      // time since last tick
    sim.tick(delta_ms)    // advance all streams
    map grid → screen_buf // core Cell → crossterm Cell
    screen_buf.flush()    // write dirty cells to terminal
}
```

Signal handling uses `signal_hook::flag::register()` with an `Arc<AtomicBool>`, checked once per frame.

---

## 5. Color Mapping

The Go reference uses named ANSI palette colors (e.g., `tcell.ColorGreen` → ANSI 2). These are **remapped by the terminal's color scheme**, causing the effect to look wrong on many themes (Solarized, Dracula, Gruvbox, etc.).

The Rust version uses **explicit 24-bit RGB values** via `Color::Rgb { r, g, b }`:

| Go tcell | RGB Value | Usage |
|----------|-----------|-------|
| `ColorBlack` | `#000000` | Background, erased cells |
| `ColorGreen` | `#00AA00` | Mid-stream body (66%) |
| `ColorLime` | `#55FF55` | Mid-stream body (34%) |
| `ColorSilver` | `#AAAAAA` | Head character (33%) |
| `ColorWhite` | `#FFFFFF` | Head character (67%) |

This requires true color support, which covers virtually all modern terminal emulators.

---

## 6. Algorithms

### 6.1 Simulation::tick(delta_ms)

Called once per frame. Iterates all columns, processing spawn delays and streams:

```
fn tick(&mut self, delta_ms: u32):
    delta_ms = min(delta_ms, 1000)  // clamp to prevent spiral on lag spikes
    max_streams = 1 + height / 10

    for each column:
        // Process spawn delay
        if Delaying { remaining_ms }:
            remaining_ms -= delta_ms
            if remaining_ms <= 0 and streams.len() < max_streams:
                spawn new Stream(speed=30+rand(0..110), length=10+rand(0..8))
                set state = Idle

        // Process streams (retain_mut pattern)
        signal_new_stream = false
        streams.retain_mut(|stream| {
            stream.accumulated_ms += delta_ms

            while accumulated_ms >= speed_ms:
                accumulated_ms -= speed_ms

                // Head advancement
                if !head_done and head_pos <= height:
                    new_char = random_char()
                    render prev head pos with mid-stream color (GREEN 66% / LIME 34%)
                    render current head pos with head color (SILVER 33% / WHITE 67%)
                    head_pos += 1
                else:
                    head_done = true

                // Tail advancement
                if tail_pos > 0 or head_pos >= length:
                    if !tail_signaled:
                        signal_new_stream = true
                        tail_signaled = true
                    if tail_pos < height:
                        clear cell at tail_pos
                        tail_pos += 1
                    else:
                        return false  // remove stream
            return true  // keep stream
        })

        // Handle new-stream signal
        if signal_new_stream and state == Idle:
            state = Delaying { remaining_ms: rand(0..9000) }
```

### 6.2 Resize

On terminal resize, both `Simulation::resize()` and `ScreenBuffer::resize()` are called:

```
fn resize(&mut self, width, height):
    clear entire grid
    truncate columns to new width (or extend with new Delaying columns)
    reset all existing columns (clear streams, set new random delay)
```

This is simpler than the plan's column manager approach (which had to send stop signals to column worker threads and wait for acknowledgment). Resizing is instant — just data mutation.

---

## 7. Implementation Steps

### Phase 1: Core Library (`rsmatrix-core`)

1. **Scaffold workspace** — Create workspace `Cargo.toml`, three crate directories
2. **Character sets** — `charset.rs` with static slices, `OnceLock` combined set, atomic switching
3. **Types** — `types.rs` with `Sizes` struct (`max_streams_per_column` computation)
4. **Simulation engine** — `simulation.rs` with `Cell`, `Stream`, `Column`, `SpawnState`, `Simulation::new()`, `tick()`, `resize()`, `grid()`

### Phase 2: Terminal Frontend (`rsmatrix-cli`)

5. **CLI parsing** — `clap` derive with `--ascii`, `--kana`, `--fps` flags, validation
6. **Screen buffer** — `screen.rs` with dirty-cell tracking and flush
7. **Terminal init/cleanup** — Raw mode, alternate screen, cursor hide/show
8. **Event loop** — `event::poll()` frame timer, key handling, resize handling, SIGINT
9. **Rendering bridge** — Map `Simulation` grid cells to `ScreenBuffer` cells each frame

### Phase 3: FFI Layer (`rsmatrix-ffi`)

10. **C FFI** — `rsmatrix_create`, `rsmatrix_destroy`, `rsmatrix_tick`, `rsmatrix_resize`, `rsmatrix_get_grid`, `rsmatrix_grid_width`, `rsmatrix_grid_height`, `rsmatrix_set_charset`

### Phase 4: Platform Screensavers

11. **macOS screensaver** — Swift `ScreenSaverView` subclass consuming `rsmatrix-ffi` via bridging header, `Makefile` for build/install

---

## 8. Verification

1. **Build**: `cargo build` and `cargo build --release` succeed with no warnings
2. **CLI flags**:
   - `cargo run -- --help` prints usage info
   - `cargo run -- --fps 0` prints FPS out-of-range error and exits with code 1
   - `cargo run -- --unknown` prints help hint
   - `cargo run -- --ascii` runs with ASCII characters only
   - `cargo run -- --kana` runs with katakana only
   - `cargo run` (no flags) runs with combined character set
3. **Visual correctness**: Characters cascade down in green columns with bright white/silver heads
4. **Runtime keys**: q quits, c clears, k switches to kana, b switches to combined, +/- adjust speed, = resets speed, Ctrl+L redraws
5. **Resize handling**: Resize the terminal window — columns should be added/removed dynamically
6. **Clean exit**: Terminal is properly restored after quitting (cursor visible, normal mode, original screen)
7. **Startup/exit messages**: Startup and exit messages are printed correctly
8. **macOS screensaver**: `make saver && make install` builds and installs the screensaver bundle
