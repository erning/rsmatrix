# rsmatrix: Rust Implementation Plan

## Context

This project implements a Matrix digital rain terminal effect in Rust, based on the product requirements in `docs/requirements.md`. An existing Go reference implementation exists in `gomatrix/`. The Rust version (`rsmatrix`) should faithfully reproduce the same visual effect and behavior while using idiomatic Rust patterns.

The Go version uses goroutines (lightweight threads) with channels for concurrency, and `tcell` for terminal rendering. The Rust version will use OS threads with `crossbeam-channel` for Go-style `select!`, and `crossterm` for terminal rendering.

---

## 1. Dependencies

```toml
[package]
name = "rsmatrix"
version = "0.1.0"
edition = "2021"
description = "Matrix digital rain terminal effect"

[dependencies]
crossterm = "0.28"           # Terminal: raw mode, alternate screen, events, styling
clap = { version = "4", features = ["derive"] }  # CLI argument parsing
rand = "0.8"                 # Random number generation
log = "0.4"                  # Logging facade
simplelog = "0.12"           # File-based logger implementation
signal-hook = "0.3"          # Unix signal handling (SIGINT, SIGTERM)
dirs = "6"                   # Home directory resolution
crossbeam-channel = "0.5"    # Multi-producer multi-consumer channels with select!

[profile.release]
opt-level = 3
lto = true
strip = true
```

**Rationale**:
- `crossterm` over `ratatui`: we need direct cell-level rendering, not widgets. crossterm is the closest analog to Go's tcell.
- `crossbeam-channel` over `std::sync::mpsc`: the column worker and stream worker both need to `select!` on multiple channels simultaneously (stop signal vs. work signal/timeout), which `std::sync::mpsc` does not support.
- `simplelog`: minimal file-based logger that implements the `log` crate facade.
- No async runtime (tokio, etc.) — OS threads + channels faithfully mirrors Go's goroutine/channel model and keeps the dependency tree small.

---

## 2. Project Structure

```
rsmatrix/
├── Cargo.toml
├── Dockerfile
├── src/
│   ├── main.rs        # Entry point, CLI, terminal init, event loop, shutdown
│   ├── screen.rs      # ScreenBuffer: shared cell grid with dirty-cell flushing
│   ├── column.rs      # ColumnManager thread + ColumnWorker thread (1 per column)
│   ├── stream.rs      # Stream worker thread (1 per raindrop)
│   ├── charset.rs     # Character set definitions and atomic switching
│   └── types.rs       # Shared types: Sizes struct
```

---

## 3. Data Types

### 3.1 `src/types.rs` — Shared Types

```rust
pub struct Sizes {
    pub width: u16,
    pub height: u16,
    pub max_streams_per_column: u16,  // 1 + height / 10
}
```

Constructor `Sizes::new(width, height)` computes `max_streams_per_column`.

### 3.2 `src/charset.rs` — Character Sets

Define three character sets as static slices:

- `HALF_WIDTH_KANA: &[char]` — 63 chars, U+FF61 through U+FF9F
- `ALPHA_NUMERICS: &[char]` — 62 chars, A-Z, a-z, 0-9
- `ALL_CHARACTERS: LazyLock<Vec<char>>` — concatenation of kana + alphanumerics (125 chars)

Use a global `AtomicUsize` to store the active charset index (0=combined, 1=ascii, 2=kana). Provide:
- `pub fn active_characters() -> &[char]` — returns the active charset slice
- `pub fn set_charset(mode: usize)` — atomically updates the index

This is lock-free. Stream workers call `active_characters()` on every tick.

### 3.3 `src/screen.rs` — Screen Buffer

Since crossterm has no internal cell buffer (unlike Go's tcell), we must build one.

```rust
struct Cell {
    ch: char,
    fg: Color,       // crossterm::style::Color
    bg: Color,
    dirty: bool,
}

pub struct ScreenBuffer {
    cells: Vec<Vec<Cell>>,  // cells[row][col]
    width: u16,
    height: u16,
}
```

Methods:
- `new(width, height)` — allocate grid, all cells = space / `Rgb(0,0,0)` / `Rgb(0,0,0)` (true black, not named ANSI black)
- `set_cell(col: i32, row: i32, fg, bg, ch)` — bounds-checked (silently ignore out-of-bounds, including negative row like -1 on first tick), marks cell dirty
- `clear()` — fill all cells with space/black/black, mark dirty
- `sync()` — mark ALL cells dirty (forces full redraw on next flush)
- `flush(stdout)` — iterate cells, write only dirty ones via `crossterm::queue!(MoveTo, SetForegroundColor, SetBackgroundColor, Print)`, then `stdout.flush()`, clear dirty flags
- `resize(width, height)` — reallocate grid

Wrap in `Arc<Mutex<ScreenBuffer>>` for sharing. Stream workers lock briefly for `set_cell` (single cell write = nanoseconds). The flusher holds the lock during `flush()` (iterating dirty cells).

### 3.4 `src/stream.rs` — Stream (Raindrop)

```rust
pub struct Stream {
    column: u16,
    speed: u64,          // milliseconds per tick, range [30, 139]
    length: i32,         // max visible chars, range [10, 17]
    head_pos: i32,       // current head y-position (signed for -1 on first tick)
    tail_pos: i32,       // current tail y-position
    head_done: bool,
    stop_rx: Receiver<()>,
    new_stream_tx: Sender<()>,          // signal parent to spawn next stream
    screen: Arc<Mutex<ScreenBuffer>>,
    sizes: Arc<RwLock<Sizes>>,
    stream_id: usize,
    stream_set: Arc<Mutex<HashSet<usize>>>,  // parent's stream tracking
}
```

### 3.5 `src/column.rs` — Column Worker

```rust
struct ColumnWorker {
    column: u16,
    stop_rx: Receiver<()>,
    new_stream_rx: Receiver<()>,
    new_stream_tx: Sender<()>,   // cloned into each stream
    streams: Arc<Mutex<HashSet<usize>>>,
    screen: Arc<Mutex<ScreenBuffer>>,
    sizes: Arc<RwLock<Sizes>>,
    next_stream_id: usize,
}
```

---

## 4. Concurrency Architecture

### 4.1 Thread Map

| Thread | Count | Lifetime | Purpose |
|---|---|---|---|
| Main | 1 | Entire program | CLI, terminal init, event loop, shutdown |
| Event Poller | 1 | Entire program | `crossterm::event::read()` → channel |
| Screen Flusher | 1 | Entire program | Calls `ScreenBuffer::flush()` at FPS rate |
| Column Manager | 1 | Entire program | Creates/destroys ColumnWorkers on resize |
| Column Worker | 1 per column | Created/destroyed on resize | Manages stream lifecycle for one column |
| Stream Worker | 1 per raindrop | Self-terminating | Advances head/tail for one raindrop |

### 4.2 Channel Map

| Channel | Rust Type | Buffer | Producer → Consumer |
|---|---|---|---|
| sizes_tx/rx | `crossbeam_channel` | bounded(0) | Main → Column Manager |
| event_tx/rx | `crossbeam_channel` | bounded(0) | Event Poller → Main |
| signal_tx/rx | `crossbeam_channel` | bounded(1) | Signal handler → Main |
| new_stream_tx/rx | `crossbeam_channel` | bounded(1) | Column Manager / Stream → Column Worker |
| col_stop_tx/rx | `crossbeam_channel` | bounded(1) | Column Manager → Column Worker |
| stream_stop_tx/rx | `crossbeam_channel` | bounded(0) | Column Worker → Stream |

### 4.3 Shared State

| State | Rust Type | Writers | Readers |
|---|---|---|---|
| Screen buffer | `Arc<Mutex<ScreenBuffer>>` | Stream workers, main (clear/sync) | Flusher |
| Terminal sizes | `Arc<RwLock<Sizes>>` | Main event loop (on resize) | Stream workers |
| FPS duration | `Arc<AtomicU64>` (microseconds) | Main event loop (+/-/=) | Flusher |
| Active charset | `AtomicUsize` (global static) | Main event loop (k/b) | Stream workers |

### 4.4 Thread Stack Size

Stream worker threads should use a reduced stack size (64 KB) since they only perform simple arithmetic and channel operations. Use `std::thread::Builder::new().stack_size(64 * 1024)`.

---

## 5. Color Mapping

The Go reference uses named ANSI palette colors (e.g., `tcell.ColorGreen` → ANSI 2). These are **remapped by the terminal's color scheme**, causing the effect to look wrong on many themes (Solarized, Dracula, Gruvbox, etc.). Common issues include the "black" background rendering as visible grey, and greens shifting to different hues.

The Rust version **must use explicit 24-bit RGB values** via `Color::Rgb { r, g, b }` to ensure consistent appearance regardless of terminal theme:

| Go tcell | ANSI Code | RGB Value | crossterm Color | Usage |
|---|---|---|---|---|
| `ColorBlack` | 0 | `#000000` | `Color::Rgb { r: 0, g: 0, b: 0 }` | Background, erased cells |
| `ColorGreen` | 2 | `#00AA00` | `Color::Rgb { r: 0, g: 170, b: 0 }` | Mid-stream body (66%) |
| `ColorLime` | 10 | `#55FF55` | `Color::Rgb { r: 85, g: 255, b: 85 }` | Mid-stream body (34%) |
| `ColorSilver` | 7 | `#AAAAAA` | `Color::Rgb { r: 170, g: 170, b: 170 }` | Head character (33%) |
| `ColorWhite` | 15 | `#FFFFFF` | `Color::Rgb { r: 255, g: 255, b: 255 }` | Head character (67%) |

This requires a terminal that supports true color (24-bit), which covers virtually all modern terminal emulators.

---

## 6. Detailed Algorithm Specifications

### 6.1 Stream Worker `run()` Loop

Reference: `gomatrix/stream.go:23-83`

```
loop {
    select! {
        recv(stop_rx) -> _ => {
            log "Stream on SD {column} was stopped."
            break
        }
        default(Duration::from_millis(speed)) => {
            // HEAD ADVANCEMENT
            if !head_done && head_pos <= screen_height {
                new_char = random char from active charset
                // Re-render previous head position with mid-stream color
                mid_color = if rand(0..100) < 66 { Rgb(0,170,0) } else { Rgb(85,255,85) }
                screen.set_cell(column, head_pos - 1, mid_color, Rgb(0,0,0), last_char)
                // Render current head position with head color
                head_color = if rand(0..100) < 33 { Rgb(170,170,170) } else { Rgb(255,255,255) }
                screen.set_cell(column, head_pos, head_color, Rgb(0,0,0), new_char)
                last_char = new_char
                head_pos += 1
            } else {
                head_done = true
            }

            // TAIL ADVANCEMENT
            if tail_pos > 0 || head_pos >= length {
                if tail_pos == 0 {
                    // First tail movement — signal parent for new stream
                    new_stream_tx.try_send(())
                }
                if tail_pos < screen_height {
                    screen.set_cell(column, tail_pos, Rgb(0,0,0), Rgb(0,0,0), ' ')
                    tail_pos += 1
                } else {
                    break  // stream terminates
                }
            }
        }
    }
}
// Remove self from parent's stream set
stream_set.lock().remove(stream_id)
```

Key details:
- `head_pos` starts at 0; on first tick, re-render targets row -1 (off-screen, ignored by bounds check)
- `screen_height` is read from shared `Sizes` via `RwLock`
- `try_send` on `new_stream_tx` (non-blocking) because the channel is bounded(1)

### 6.2 Column Worker `run()` Loop

Reference: `gomatrix/stream.go:95-138`

```
loop {
    select! {
        recv(stop_rx) -> _ => {
            // Lock streams, send stop to all, log, return
            streams.lock().drain() — for each, send stop signal
            log "StreamDisplay on column {column} stopped."
            return
        }
        recv(new_stream_rx) -> _ => {
            // Random spawn delay
            select! {
                recv(stop_rx) -> _ => { handle stop; return }
                default(Duration::from_millis(rand(0..9000))) => {
                    // Create stream with random params
                    speed = 30 + rand(0..110)    // [30, 139]
                    length = 10 + rand(0..8)     // [10, 17]
                    // Create Stream, add to streams set, spawn thread
                }
            }
        }
    }
}
```

The spawn delay is interruptible — if a stop signal arrives during the delay, the column worker exits immediately.

### 6.3 Column Manager

Reference: `gomatrix/main.go:168-217`

```
let mut last_width = 0;
for new_sizes in sizes_rx {
    log "New width: {width}"
    diff_width = new_sizes.width - last_width
    if diff_width == 0 {
        log "Got resize over channel, but diffWidth = 0"
        continue
    }
    if diff_width > 0 {
        log "Starting {diff_width} new SD's"
        for col in last_width..new_sizes.width {
            create ColumnWorker for col, spawn thread, send initial new_stream signal
        }
    }
    if diff_width < 0 {
        log "Closing {-diff_width} SD's"
        for col in (new_sizes.width..last_width).rev() {
            send stop to column worker, remove from map
        }
    }
    last_width = new_sizes.width
}
```

Note: The Go version has an off-by-one bug in the close loop (`closeColumn > newSizes.width` should be `>=`). The Rust version should use the range `new_sizes.width..last_width` which correctly includes all columns that need removal.

---

## 7. Implementation Steps

Build incrementally. Each step should compile and be testable.

### Step 1: Project Scaffold

- Run `cargo init` in the project root (creates `Cargo.toml` and `src/main.rs`)
- Add all dependencies to `Cargo.toml`
- Create empty module files: `src/types.rs`, `src/charset.rs`, `src/screen.rs`, `src/column.rs`, `src/stream.rs`
- Add `mod` declarations to `src/main.rs`
- Add `/target/` to the existing `.gitignore` (or create one)
- Verify: `cargo build` succeeds

### Step 2: Types and Character Sets

- Implement `Sizes` in `src/types.rs`
- Implement character set arrays and atomic switching in `src/charset.rs`
- Verify: `cargo build` succeeds

### Step 3: CLI Parsing

Implement in `src/main.rs` using clap derive:

```rust
#[derive(Parser)]
#[command(name = "rsmatrix")]
struct Args {
    #[arg(short = 'a', long)]
    ascii: bool,
    #[arg(short = 'k', long)]
    kana: bool,
    #[arg(short = 'l', long)]
    log: bool,
    #[arg(short = 'p', long)]
    profile: Option<String>,
    #[arg(long, default_value_t = 25)]
    fps: u32,
}
```

Handle validation:
- FPS range 1-60: print `"Error: option --fps not within range 1-60"`, exit(1)
- Unknown flags: use `Args::try_parse()`, catch clap errors, print `"Use --help to view all available options."`
- Positional arguments: detect and print `"Unknown argument '<arg>'."`
- `--ascii` takes precedence over `--kana` (check `ascii` first)

Print startup message: `"Opening connection to The Matrix.. Please stand by.."`
Print FPS info: `"fps sleep time: {duration}"` where duration format should match Go's `time.Duration.String()` (e.g., `40ms` for 25 FPS, `1s` for 1 FPS, `16.666ms` for 60 FPS). Use the formula: `1_000_000 / fps` microseconds.

Verify: `cargo run -- --help`, `cargo run -- --fps 0`, `cargo run -- --ascii`, `cargo run -- unknown_arg`

### Step 4: Logging Setup

- If `--log`: open `~/.gomatrix-log` (use `dirs::home_dir()`) in append mode
- If not `--log`: log to `/dev/null` (or use `simplelog`'s `WriteLogger` with a sink)
- Initialize `simplelog::WriteLogger` with `LevelFilter::Debug`
- Log separator: `"-------------"`
- Log startup: `"Starting gomatrix. This logfile is for development/debug purposes."`

Verify: `cargo run -- --log` then check `~/.gomatrix-log`

### Step 5: Screen Buffer

Implement `src/screen.rs`:
- `Cell` struct with `ch`, `fg`, `bg`, `dirty` fields
- `ScreenBuffer` struct with `cells` grid, `width`, `height`
- `new()`: initialize grid with space/Black/Black cells
- `set_cell(col: i32, row: i32, ...)`: bounds-check (ignore negative or >= dimensions), set cell and mark dirty
- `clear()`: fill all cells with defaults, mark all dirty
- `sync()`: mark all cells dirty (forces full repaint)
- `flush(stdout)`: write dirty cells using `crossterm::queue!(MoveTo, SetColors, Print)`, then `stdout.flush()`, clear dirty flags
- `resize(width, height)`: reallocate the grid

Verify: unit test that creates a buffer, sets cells, and flushes to a `Vec<u8>` sink

### Step 6: Terminal Init and Cleanup

In `src/main.rs`:
- Enable raw mode: `crossterm::terminal::enable_raw_mode()`
- Enter alternate screen, hide cursor: `crossterm::execute!(stdout, EnterAlternateScreen, Hide)`
- Get initial size: `crossterm::terminal::size()`
- Create `ScreenBuffer` with initial size
- Create `TerminalGuard` struct with `Drop` impl that restores terminal state:
  ```rust
  impl Drop for TerminalGuard {
      fn drop(&mut self) {
          let _ = disable_raw_mode();
          let _ = execute!(io::stdout(), LeaveAlternateScreen, Show);
      }
  }
  ```

At this point, the program should enter the terminal, show a blank screen, and exit cleanly. Verify manually.

### Step 7: Event Poller and Signal Handler

- Spawn event poller thread: loop calling `crossterm::event::read()`, send on `event_tx`
- Set up signal handler: use `signal_hook` to register SIGINT and SIGTERM, send on `signal_tx`
- Main event loop skeleton: `crossbeam_channel::select!` on `event_rx` and `signal_rx`
- Handle quit keys: Ctrl+C, Ctrl+Z, `q` → break loop
- Handle `c` → `screen.lock().clear()`
- Handle Ctrl+L → `screen.lock().sync()`
- Handle `k` → `charset::set_charset(2)`
- Handle `b` → `charset::set_charset(0)`
- Handle `+` → increment FPS (cap 60), update AtomicU64
- Handle `-` → decrement FPS (cap 1), update AtomicU64
- Handle `=` → reset FPS to initial value
- Handle resize event → update shared `Sizes`, send on `sizes_tx`

Verify: run the app, press keys, verify quit works cleanly

### Step 8: Screen Flusher Thread

- Spawn flusher thread with its own `stdout` handle
- Loop: read `fps_micros` from `AtomicU64`, sleep that duration, lock screen buffer, call `flush(stdout)`

Verify: set a cell in the buffer from main, see it appear on screen

### Step 9: Stream Worker

Implement `Stream::run()` in `src/stream.rs` following the algorithm in Section 6.1 above.

Key implementation notes:
- Use `crossbeam_channel::select!` with `recv(stop_rx)` and `default(Duration::from_millis(speed))`
- Read `height` from `Arc<RwLock<Sizes>>` on each tick
- Call `screen.lock().unwrap().set_cell(...)` for each cell update
- Use `rand::thread_rng()` for random character selection and color probability
- On exit, lock `stream_set` and remove `stream_id`
- Spawn with `thread::Builder::new().stack_size(64 * 1024)`

### Step 10: Column Worker

Implement `ColumnWorker::run()` in `src/column.rs` following the algorithm in Section 6.2.

Key implementation notes:
- Use `crossbeam_channel::select!` on `stop_rx` and `new_stream_rx`
- Spawn delay is interruptible: use nested `select!` with `default(duration)` and `recv(stop_rx)`
- Create `Stream` with random speed and length, add to `streams` set, spawn thread
- On stop: iterate streams, send stop to each, log

### Step 11: Column Manager

Implement `run_column_manager()` in `src/column.rs` following the algorithm in Section 6.3.

Key implementation notes:
- Maintain a `HashMap<u16, (Sender<()>, Sender<()>)>` mapping column index to (stop_tx, new_stream_tx)
- On width increase: create ColumnWorkers for new columns, send initial new_stream signal
- On width decrease: send stop to removed columns, remove from map
- Fix the off-by-one bug from Go: use `new_width..last_width` range for closing

### Step 12: Wire Everything Together

In `main.rs`, after terminal init:
1. Create shared state: `Arc<Mutex<ScreenBuffer>>`, `Arc<RwLock<Sizes>>`, `Arc<AtomicU64>`
2. Get initial terminal size, create `Sizes`, update shared state
3. Spawn flusher thread
4. Spawn event poller thread
5. Spawn column manager thread
6. Send initial sizes to column manager
7. Enter main event loop
8. On loop exit: `TerminalGuard` drops (restores terminal), log shutdown, print exit message

### Step 13: Profiling Support (Stub)

For `--profile <filepath>`:
- Open the specified file at startup; on failure print `"Error opening profiling file: {error}"` and exit(1)
- Log that profiling is active
- On shutdown, close the file
- Actual CPU profiling can be added later with platform-specific tools

### Step 14: Shutdown and Exit

After breaking from the event loop:
1. `TerminalGuard` drops → restores terminal
2. `log::info!("stopping gomatrix")`
3. `println!("Thank you for connecting with Morpheus' Matrix API v4.2. Have a nice day!")`
4. Stop profiling if active
5. Process exits (all spawned threads are abandoned, same as Go version)

### Step 15: Dockerfile

```dockerfile
FROM rust:alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release

FROM scratch
COPY --from=builder /app/target/release/rsmatrix /rsmatrix
ENTRYPOINT ["/rsmatrix"]
```

Usage: `docker build -t rsmatrix .` then `docker run -ti rsmatrix`

---

## 8. Verification Plan

After implementation is complete, verify:

1. **Build**: `cargo build` and `cargo build --release` succeed with no warnings
2. **CLI flags**:
   - `cargo run -- --help` prints usage info
   - `cargo run -- --fps 0` prints `"Error: option --fps not within range 1-60"` and exits with code 1
   - `cargo run -- --fps 61` same as above
   - `cargo run -- --unknown` prints `"Use --help to view all available options."`
   - `cargo run -- somearg` prints `"Unknown argument 'somearg'."`
   - `cargo run -- --ascii` runs with ASCII characters only
   - `cargo run -- --kana` runs with katakana only
   - `cargo run` (no flags) runs with combined character set
3. **Visual correctness**: Characters cascade down in green columns with bright white/silver heads
4. **Runtime keys**: q quits, c clears, k switches to kana, b switches to combined, +/- adjust speed, = resets speed, Ctrl+L redraws
5. **Resize handling**: Resize the terminal window — columns should be added/removed dynamically
6. **Logging**: `cargo run -- --log` then verify `~/.gomatrix-log` contains debug messages
7. **Clean exit**: Terminal is properly restored after quitting (cursor visible, normal mode, original screen)
8. **Startup/exit messages**: Verify exact message text matches the requirements
