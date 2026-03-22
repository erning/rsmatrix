# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rsmatrix is a Rust reimplementation of cmatrix — the classic Matrix terminal screensaver. It uses a platform-agnostic simulation core, a terminal CLI frontend, a C FFI layer for native macOS integrations (standalone GUI app and ScreenSaver framework), and a GTK4 GUI app for Linux.

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

# Build and run the Linux GTK4 GUI app (requires gtk4-devel)
cargo run -p rsmatrix-gtk
cargo run -p rsmatrix-gtk -- --ascii

# Build macOS screensaver bundle (requires macOS + swiftc)
make saver

# Build macOS standalone GUI app
make app

# Run macOS GUI app
make run-app

# Install macOS screensaver to ~/Library/Screen Savers/
make install-saver

# Clean all build artifacts
make clean
```

`cargo test -p rsmatrix-core` runs the unit tests. `cargo check --workspace` is the quickest way to validate all crates compile.

## Workspace Architecture

```
rsmatrix-core    — Platform-agnostic simulation engine. Only depends on `rand`.
                   Exports: Simulation, Cell (#[repr(C)]), charset, types.

rsmatrix-cli     — Terminal frontend. Uses crossterm for rendering, clap for CLI args,
                   signal-hook for SIGINT. Contains ScreenBuffer with dirty-cell tracking.

rsmatrix-ffi     — C FFI wrapper around rsmatrix-core. Exposes 9 extern "C" functions
                   (create, destroy, tick, resize, clear, get_grid, grid_width,
                   grid_height, set_charset). Consumed by the macOS Swift app and screensaver
                   via bridging header.

rsmatrix-gtk     — Linux GTK4 GUI app. Uses gtk4-rs (v4_12) + Pango + Cairo for rendering.
                   Directly depends on rsmatrix-core (no FFI).
                   Prerequisite: gtk4-devel (Fedora) or libgtk-4-dev (Debian/Ubuntu).

macos/                — All macOS native code (Swift/AppKit/Metal, not Cargo crates).
  MetalRenderer.swift   — Metal GPU rendering: instanced glyph drawing, bloom, CRT scanlines,
                          background blur/wallpaper. Shared by app and screensaver.
  MatrixRenderer.swift  — CoreText renderer using CTFontDrawGlyphs with font fallback.
  Shaders.metal         — Metal shader source (compiled to .metallib at build time).
  rsmatrix-ffi-Bridging.h — Shared C bridging header for FFI functions.
  saver/                — ScreenSaverView (.saver bundle) with configure sheet (options UI).
  app/                  — Standalone GUI app (.app bundle). NSWindow + MTKView.
    main.swift            — NSApplication entry, CLI arg parsing, menu bar setup.
    MatrixView.swift      — MTKView subclass: frame loop, renderer switching, keyboard, effects.
    MatrixRenderer.swift  — App-specific re-export (same as shared MatrixRenderer).
```

**Data flow**: External frontends create a `Simulation`, call `tick(delta_ms)` each frame, then read the flat `grid: Vec<Cell>` for rendering. The simulation is pure data — no threads, no I/O.

## Key Design Decisions

- **Single-threaded event loop**: `crossterm::event::poll(frame_duration)` is both the frame timer and input listener. No async runtime.
- **Delta-time accumulator**: Each stream tracks `accumulated_ms`; frame-rate independent advancement.
- **Flat row-major grid**: `grid: Vec<Cell>` with `#[repr(C)]` cells (codepoint: u32, r/g/b: u8) — cache-friendly and FFI-passable as raw pointer.
- **Lock-free charset switching**: Character set selection uses `AtomicUsize` for thread-safe toggling without mutexes.
- **Color values are hardcoded 24-bit RGB**, not ANSI palette indices.
- **Metal GPU rendering on macOS**: Instanced draw calls render glyphs from a pre-rasterized font atlas texture. Post-processing effects (bloom via multi-pass Gaussian blur, CRT scanlines) are applied as fullscreen shader passes. Frame rate adapts to display refresh rate via `CGDisplayCopyDisplayMode`.
- **Background blur**: In windowed mode, `NSVisualEffectView` provides live desktop blur behind the transparent window. In fullscreen, the wallpaper image is captured via `NSWorkspace.desktopImageURL`, Gaussian-blurred with CIFilter, darkened, and composited as a Metal background texture.
- **macOS screensaver known limitations**: On Sonoma (14)+, Apple's `legacyScreenSaver.appex` host has unresolved lifecycle bugs (instances not destroyed, `stopAnimation()` not called, process not terminating). Preview is intentionally disabled. The standalone app (`make run-app`) is the more reliable delivery method on modern macOS.
