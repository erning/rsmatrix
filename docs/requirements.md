# Matrix Digital Rain: Product Requirements Document

## 1. Overview

This application renders the iconic "Matrix digital rain" effect in a terminal emulator. Columns of characters cascade vertically down the screen in green-tinted streams, evoking the aesthetic of the Matrix film franchise.

The application:

- Fills the terminal with independent vertical columns, each producing sequential streams of random characters that fall from top to bottom.
- Uses half-width Japanese katakana and ASCII alphanumeric characters (with user-selectable modes).
- Renders in green/lime tones with bright white/silver leading characters.
- Supports runtime speed adjustment, character set switching, and terminal resize.
- Runs until the user quits.

---

## 2. Character Sets

### 2.1 Half-Width Katakana (63 characters)

Unicode codepoints U+FF61 through U+FF9F:

```
U+FF61  ｡    U+FF62  ｢    U+FF63  ｣    U+FF64  ､    U+FF65  ･
U+FF66  ｦ    U+FF67  ｧ    U+FF68  ｨ    U+FF69  ｩ    U+FF6A  ｪ
U+FF6B  ｫ    U+FF6C  ｬ    U+FF6D  ｭ    U+FF6E  ｮ    U+FF6F  ｯ
U+FF70  ｰ    U+FF71  ｱ    U+FF72  ｲ    U+FF73  ｳ    U+FF74  ｴ
U+FF75  ｵ    U+FF76  ｶ    U+FF77  ｷ    U+FF78  ｸ    U+FF79  ｹ
U+FF7A  ｺ    U+FF7B  ｻ    U+FF7C  ｼ    U+FF7D  ｽ    U+FF7E  ｾ
U+FF7F  ｿ    U+FF80  ﾀ    U+FF81  ﾁ    U+FF82  ﾂ    U+FF83  ﾃ
U+FF84  ﾄ    U+FF85  ﾅ    U+FF86  ﾆ    U+FF87  ﾇ    U+FF88  ﾈ
U+FF89  ﾉ    U+FF8A  ﾊ    U+FF8B  ﾋ    U+FF8C  ﾌ    U+FF8D  ﾍ
U+FF8E  ﾎ    U+FF8F  ﾏ    U+FF90  ﾐ    U+FF91  ﾑ    U+FF92  ﾒ
U+FF93  ﾓ    U+FF94  ﾔ    U+FF95  ﾕ    U+FF96  ﾖ    U+FF97  ﾗ
U+FF98  ﾘ    U+FF99  ﾙ    U+FF9A  ﾚ    U+FF9B  ﾛ    U+FF9C  ﾜ
U+FF9D  ﾝ    U+FF9E  ﾞ    U+FF9F  ﾟ
```

### 2.2 ASCII Alphanumeric (62 characters)

- Uppercase Latin: A-Z (U+0041 - U+005A, 26 characters)
- Lowercase Latin: a-z (U+0061 - U+007A, 26 characters)
- Digits: 0-9 (U+0030 - U+0039, 10 characters)

### 2.3 Combined Set (125 characters)

The union of the half-width katakana set and the ASCII alphanumeric set, with katakana listed first.

### 2.4 Character Set Modes

| Mode        | Character Count | Activation               |
|-------------|-----------------|--------------------------|
| Combined    | 125             | Default (no flag), or `b` key at runtime |
| ASCII-only  | 62              | `--ascii` / `-a` flag    |
| Kana-only   | 63              | `--kana` / `-k` flag, or `k` key at runtime |

The `--ascii` and `--kana` flags are mutually exclusive. If both are provided, `--ascii` takes precedence (first-match evaluation).

Character selection within the active set is uniformly random.

---

## 3. Command-Line Interface

### 3.1 Flags

| Flag             | Short | Type    | Default | Description |
|------------------|-------|---------|---------|-------------|
| `--ascii`        | `-a`  | boolean | false   | Use ASCII/alphanumeric characters only |
| `--kana`         | `-k`  | boolean | false   | Use Japanese half-width katakana only |
| `--fps`          |       | integer | 25      | Target frames per second (screen refresh rate) |
| `--help`         | `-h`  | boolean | false   | Display usage information and exit |

### 3.2 Validation

- **`--fps`**: Must be in the range 1-60 inclusive. If outside this range, print the error message `Error: option --fps not within range 1-60` and exit with code 1.
- **Unknown flags / positional arguments**: Handled by clap's default error formatting (displays the error, usage hint, and suggestion for the closest matching flag). Exits with code 2.

---

## 4. Runtime Keyboard Controls

| Key(s)       | Action |
|--------------|--------|
| `Ctrl+C`     | Quit the application |
| `Ctrl+Z`     | Quit the application |
| `q`          | Quit the application |
| `Ctrl+L`     | Synchronize/redraw the screen |
| `c`          | Clear the screen |
| `a`          | Switch character set to ASCII only |
| `k`          | Switch character set to katakana only |
| `b`          | Switch character set to combined (katakana + ASCII) |
| `+`          | Increase FPS by 1 (capped at 60) |
| `-`          | Decrease FPS by 1 (capped at 1) |
| `=`          | Reset FPS to the initial value from the command-line flag |

---

## 5. Visual Rendering Specification

### 5.1 Architecture

The terminal is logically divided into vertical **columns** (one per terminal column, indexed 0 to `width - 1`). Each column runs a **column worker** that produces sequential **streams** of falling characters.

### 5.2 Data Model

**Column Worker** (one per terminal column):
- `column`: integer, the x-coordinate (0-indexed)
- `streams`: set of currently active streams in this column
- `newStream`: signaling mechanism to trigger spawning a new stream
- `stop`: signaling mechanism for shutdown

**Stream** (one per falling "raindrop"):
- `column`: inherited from parent column worker
- `speed`: integer, milliseconds between ticks (determines fall rate)
- `length`: integer, maximum number of visible characters before tail begins clearing
- `headPos`: integer, current y-position of the leading character (0-indexed)
- `tailPos`: integer, current y-position of the trailing eraser (0-indexed)
- `headDone`: boolean, true once the head has passed beyond the bottom of the screen
- `stop`: signaling mechanism for shutdown

### 5.3 Stream Lifecycle

#### 5.3.1 Spawning

A new stream is spawned in a column when:
1. The column worker is first created (initial stream), or
2. A previous stream's tail begins advancing for the first time (see Section 5.3.3).

Before creating the stream, the column worker waits a random delay:

```
spawnDelay = random(0, 8999) milliseconds
```

The stream is then created with randomized parameters:

```
speed  = 30 + random(0, 109)    → range [30, 139] milliseconds
length = 10 + random(0, 7)      → range [10, 17] characters
```

Initial state: `headPos = 0`, `tailPos = 0`, `headDone = false`.

#### 5.3.2 Head Advancement

On each stream tick (every `speed` milliseconds):

1. **If the head is still active** (`headDone` is false AND `headPos <= screenHeight`):
   - Select a random character from the active character set.
   - Re-render the **previous head position** (`headPos - 1`) with the previously selected character using a **mid-stream color** (see Section 5.4).
   - Render the **current head position** (`headPos`) with the new character using a **head color** (see Section 5.4).
   - Remember the new character for re-rendering on the next tick.
   - Increment `headPos`.

2. **If the head has passed the bottom** (`headPos > screenHeight`):
   - Set `headDone = true`. No further head rendering occurs.

Note: On the very first tick (`headPos = 0`), the re-render targets row -1, which is off-screen and produces no visible effect. This is expected behavior.

#### 5.3.3 Tail Advancement

On each stream tick, after head processing:

1. **Tail activation condition**: The tail advances if `tailPos > 0` OR `headPos >= length`.
   - This means the tail begins advancing once the head has traveled at least `length` positions.

2. **First tail movement**: When the tail advances from position 0 for the first time, signal the column worker to spawn a new stream (Section 5.3.1). This creates the cascading effect of overlapping streams in the same column.

3. **Tail clearing**: If `tailPos < screenHeight`:
   - Clear the cell at `(column, tailPos)` by writing a space character with black-on-black styling.
   - Increment `tailPos`.

4. **Tail completion**: If `tailPos >= screenHeight`, the stream terminates.

#### 5.3.4 Termination

When a stream terminates (tail reaches the bottom or a stop signal is received), it removes itself from the parent column worker's stream set.

### 5.4 Color System

All rendering uses a true black background. Five foreground colors are used:

| Color   | RGB Value  | Usage | Description |
|---------|------------|-------|-------------|
| Black   | `#000000`  | Erased cells, default background | Invisible (black on black) |
| Green   | `#00AA00`  | Mid-stream body characters | Standard green, used 66% of the time |
| Lime    | `#55FF55`  | Mid-stream body characters | Bright/bold green, used 34% of the time |
| Silver  | `#AAAAAA`  | Leading head character | Gray tone, used 33% of the time |
| White   | `#FFFFFF`  | Leading head character | Bright white, used 67% of the time |

**Important — use fixed RGB values, not named ANSI colors.**
The Go reference implementation (`gomatrix`) uses named ANSI palette colors (e.g., ANSI 0 "Black", ANSI 2 "Green"). These named colors are **remapped by the terminal emulator's color scheme**, so the actual displayed colors vary across terminals and themes. Many popular themes (Solarized, Dracula, Gruvbox, etc.) redefine ANSI black to a visible grey, making the supposedly-invisible background cells visible and breaking the effect.

To ensure a consistent Matrix aesthetic regardless of terminal theme, implementations **must** use explicit 24-bit RGB color values (true color) rather than named/indexed ANSI colors. The RGB values listed above correspond to the standard VGA palette that the original ANSI codes were designed to represent.

**Probability distributions:**

Mid-stream color (applied when re-rendering the character behind the head):
```
if random(0, 99) < 66 → Green   (66% probability)
else                   → Lime    (34% probability)
```

Head color (applied to the leading character):
```
if random(0, 99) < 33 → Silver  (33% probability)
else                   → White   (67% probability)
```

### 5.5 Streams Per Column

The maximum number of concurrent streams allowed per column is calculated as:

```
maxStreamsPerColumn = 1 + floor(screenHeight / 10)
```

This allows approximately one additional stream for every 10 rows of terminal height.

---

## 6. Concurrency Model

> **Implementation note**: The sections below describe the concurrency model from the Go reference implementation (`gomatrix`), which uses one goroutine per column and per stream. The Rust implementation (`rsmatrix`) intentionally uses a **single-threaded event loop** with a tick-based simulation engine instead. All stream and column logic runs synchronously in `Simulation::tick()`, driven by delta-time accumulators. See `docs/design-notes.md` for the rationale behind this architectural change.

The Go reference uses concurrent, independently-executing workers communicating via channels and shared state protected by mutual exclusion.

### 6.1 Worker Types (Go reference)

| Worker              | Count                      | Purpose |
|---------------------|----------------------------|---------|
| Main / Event Loop   | 1                          | Parses flags, initializes terminal, dispatches events and signals |
| Column Manager      | 1                          | Monitors terminal resizes; creates/destroys column workers |
| Column Worker       | 1 per terminal column      | Manages stream lifecycle for a single column |
| Stream Worker       | 1 per active stream        | Advances head and tail for a single stream |
| Screen Flusher      | 1                          | Flushes the screen buffer to the terminal at FPS rate |
| Event Poller        | 1                          | Polls for terminal events and forwards them to the main loop |

### 6.2 Communication Channels (Go reference)

| Channel         | Type             | Producer(s)            | Consumer       | Buffered | Purpose |
|-----------------|------------------|------------------------|----------------|----------|---------|
| sizesUpdate     | terminal sizes   | Main (on resize event) | Column Manager | No       | Notify of terminal dimension changes |
| newStream       | signal (boolean) | Column Manager, Stream | Column Worker  | Yes (1)  | Trigger creation of a new stream |
| column stop     | signal (boolean) | Column Manager         | Column Worker  | Yes (1)  | Signal column worker to shut down |
| stream stop     | signal (boolean) | Column Worker          | Stream Worker  | No       | Signal stream worker to shut down |
| eventChan       | terminal event   | Event Poller           | Main           | No       | Forward user input / resize events |
| sigChan         | OS signal        | Operating system       | Main           | No       | Forward interrupt/kill signals |

### 6.3 Shared State (Go reference)

- **Screen buffer**: All stream workers write to the screen buffer concurrently via `SetCell(column, row, style, character)`. The screen library handles concurrent cell writes.
- **Stream set**: Each column worker maintains a set of active streams, protected by a mutex. Locked when adding a new stream (in the column worker) or removing a terminated stream (in the stream worker).
- **Current terminal sizes**: A shared structure containing `width`, `height`, and `maxStreamsPerColumn`. Updated by the main event loop on resize. Read by stream workers to check screen boundaries.
- **Active character set**: A shared array reference. Updated by the main event loop on key press (`k`, `b`). Read by stream workers on each tick. No synchronization required as the reference swap is atomic at the application level.
- **FPS sleep duration**: Updated by the main event loop on `+`, `-`, `=` key presses. Read by the screen flusher.

---

## 7. Terminal Management

### 7.1 Initialization Sequence

1. Create a new terminal screen.
2. Initialize the screen.
3. Hide the cursor.
4. Set the default style to black foreground on black background.
5. Clear the screen.

### 7.2 Screen Flushing

A dedicated flusher worker calls the screen's `Show()` method at a regular interval derived from the current FPS setting:

```
flushInterval = floor(1,000,000 / currentFPS) microseconds
```

| FPS | Flush Interval |
|-----|----------------|
| 1   | 1,000,000 us (1 second) |
| 25  | 40,000 us (40 ms) |
| 60  | 16,666 us (~16.7 ms) |

The flusher sleeps for `flushInterval` between each flush. Stream workers write to the screen buffer at any time; the flusher periodically pushes accumulated changes to the display.

### 7.3 Resize Handling

When the terminal emulator is resized:

1. The event poller detects a resize event and forwards it to the main loop.
2. The main loop reads the new width and height, recalculates `maxStreamsPerColumn`, and sends the updated sizes to the Column Manager.
3. The Column Manager compares the new width to the previous width:
   - **Width increased**: Create new column workers for the additional columns and send an initial `newStream` signal to each.
   - **Width decreased**: Send stop signals to column workers for the removed columns. Each stopped column worker in turn stops all of its active streams.
   - **Width unchanged**: No action (height changes affect `maxStreamsPerColumn` but do not add/remove columns).

### 7.4 Finalization

On exit, the application calls the terminal screen's `Fini()` method to restore the terminal to its original state (cursor visibility, input mode, alternate screen buffer, etc.).

---

## 8. Randomness Parameters

All random values use a pseudo-random number generator seeded once at startup with the current time in nanoseconds.

| Parameter           | Formula                      | Range          | Unit         |
|---------------------|------------------------------|----------------|--------------|
| Stream speed        | `30 + random(0, 109)`        | 30 - 139       | milliseconds |
| Stream length       | `10 + random(0, 7)`          | 10 - 17        | characters   |
| Spawn delay         | `random(0, 8999)`            | 0 - 8,999      | milliseconds |
| Character selection  | `random(0, charsetLen - 1)`  | 0 - (N-1)      | index        |
| Mid-stream color    | `random(0, 99) < 66`         | Green or Lime   | —            |
| Head color          | `random(0, 99) < 33`         | Silver or White | —            |

Where `random(min, max)` returns a uniformly distributed integer in the inclusive range `[min, max]`.

---

## 9. Signal and Shutdown Handling

### 9.1 Captured Signals

The application registers handlers for:
- **Interrupt** (e.g., Ctrl+C from the shell, `SIGINT`)
- **Kill** (`SIGKILL`)

### 9.2 Shutdown Sequence

Triggered by any quit action (Ctrl+C, Ctrl+Z, `q` key, or OS signal):

1. Break out of the main event loop.
2. Finalize the terminal screen (restore original terminal state).
3. Log `"stopping gomatrix"`.
4. Print the exit message to standard output (see Section 11).
5. Stop CPU profiling if active.
6. Process exits.

Note: Individual stream and column workers are not explicitly stopped during shutdown; they are abandoned when the process exits. Only column workers stopped due to terminal resize receive explicit stop signals.

---

## 10. Logging and Profiling

> **Not implemented**: The `--log` and `--profile` flags from the Go reference are not implemented in the Rust version. The single-threaded architecture is simple enough to debug with standard tools (e.g., `RUST_LOG`, `tracing`, or a debugger) without a built-in logging facility. This section is retained for reference to the Go original.

### 10.1 Debug Logging (Go reference)

- **Activation**: `--log` / `-l` flag.
- **Log file**: `~/.gomatrix-log` (resolved via `$HOME` environment variable).
- **File mode**: Opened for read/write, created if missing, appended to if existing. Permission mode `0666`.
- **When disabled**: Log output is directed to the system null device (`/dev/null`).

### 10.2 CPU Profiling (Go reference)

- **Activation**: `--profile <filepath>` / `-p <filepath>`.
- **Behavior**: Creates the specified file at startup. Begins CPU profiling immediately. Stops profiling during the shutdown sequence.

---

## 11. Startup and Exit Messages

### 11.1 Startup Message

Printed to standard output immediately after flag parsing and profiling setup:

```
Opening connection to The Matrix.. Please stand by..
```

### 11.2 FPS Information

Printed to standard output after calculating the flush interval:

```
fps sleep time: <duration>
```

Where `<duration>` is a human-readable duration string (e.g., `40ms` for 25 FPS).

### 11.3 Exit Message

Printed to standard output after finalizing the terminal:

```
Thank you for connecting with Morpheus' Matrix API v4.2. Have a nice day!
```

### 11.4 Error Messages

| Condition | Output | Exit Code |
|-----------|--------|-----------|
| Unknown flag / positional argument | clap default error (error message, usage hint, closest-match suggestion) | 2 |
| FPS out of range (1-60) | `Error: option --fps not within range 1-60` | 1 |

---

## 12. Docker Support

> **Not implemented**: Docker support is not included in the Rust version. The Go reference's Dockerfile produced a static binary; the Rust version can be built with `cargo build --release` and distributed as a standalone binary. This section is retained for reference.

---

## Appendix A: Complete Parameter Reference

| Category | Parameter | Value / Range | Unit |
|----------|-----------|---------------|------|
| FPS | Default | 25 | frames/sec |
| FPS | Minimum | 1 | frames/sec |
| FPS | Maximum | 60 | frames/sec |
| Stream | Speed | 30 - 139 | milliseconds/tick |
| Stream | Length | 10 - 17 | characters |
| Stream | Spawn delay | 0 - 8,999 | milliseconds |
| Color | Mid-stream green probability | 66% | — |
| Color | Mid-stream lime probability | 34% | — |
| Color | Head silver probability | 33% | — |
| Color | Head white probability | 67% | — |
| Characters | Katakana count | 63 | — |
| Characters | ASCII count | 62 | — |
| Characters | Combined count | 125 | — |
| Layout | Streams per column | 1 + floor(height / 10) | max concurrent |
