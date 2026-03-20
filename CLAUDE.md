# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rsmatrix is a Rust reimplementation of cmatrix — the classic Matrix terminal screensaver. It uses a three-tier crate architecture with a platform-agnostic simulation core, a terminal CLI frontend, and a C FFI layer for native screensaver integrations (macOS ScreenSaver framework, planned Linux/Windows).

## Build Commands

```bash
# Build and run the CLI (default workspace member)
cargo run
cargo run -- --ascii --fps 30

# Build release CLI binary
cargo build --release

# Build the FFI static library (for screensaver targets)
cargo build --release -p rsmatrix-ffi

# Build a specific crate
cargo build -p rsmatrix-core

# Build macOS screensaver bundle (requires macOS + swiftc)
make saver

# Install macOS screensaver to ~/Library/Screen Savers/
make install

# Clean all build artifacts
make clean
```

There are no tests in this codebase currently. `cargo check --workspace` is the quickest way to validate all crates compile.

## Workspace Architecture

```
rsmatrix-core    — Platform-agnostic simulation engine. Only depends on `rand`.
                   Exports: Simulation, Cell (#[repr(C)]), Column, Stream, charset, types.

rsmatrix-cli     — Terminal frontend. Uses crossterm for rendering, clap for CLI args,
                   signal-hook for SIGINT. Contains ScreenBuffer with dirty-cell tracking.

rsmatrix-ffi     — C FFI wrapper around rsmatrix-core. Exposes 9 extern "C" functions
                   (create, destroy, tick, resize, clear, get_grid, grid_width,
                   grid_height, set_charset). Consumed by the macOS Swift screensaver
                   via bridging header.

screensavers/
  macos/         — Swift ScreenSaverView (.saver bundle, not a Cargo crate).
                   Uses CTFontDrawGlyphs for batch glyph rendering with automatic
                   font fallback for katakana characters. Configurable charset and FPS
                   via ScreenSaver Options panel.
  linux/         — Stub crate for future XScreenSaver integration.
  windows/       — Stub crate for future .scr integration.
```

**Data flow**: External frontends create a `Simulation`, call `tick(delta_ms)` each frame, then read the flat `grid: Vec<Cell>` for rendering. The simulation is pure data — no threads, no I/O.

## Key Design Decisions

- **Single-threaded event loop**: `crossterm::event::poll(frame_duration)` is both the frame timer and input listener. No async runtime.
- **Delta-time accumulator**: Each stream tracks `accumulated_ms`; frame-rate independent advancement.
- **Flat row-major grid**: `grid: Vec<Cell>` with `#[repr(C)]` cells (codepoint: u32, r/g/b: u8) — cache-friendly and FFI-passable as raw pointer.
- **Lock-free charset switching**: Character set selection uses `AtomicUsize` for thread-safe toggling without mutexes.
- **Color values are hardcoded 24-bit RGB**, not ANSI palette indices.

## CLI Flags and Runtime Keys

Flags: `-a`/`--ascii`, `-k`/`--kana`, `--fps N` (1-60, default 25)

Runtime: `q`/`Ctrl+C` quit, `c` clear, `k` kana, `b` combined, `+`/`-` FPS, `=` reset FPS, `Ctrl+L` full redraw.
