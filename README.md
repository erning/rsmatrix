# rsmatrix

Matrix digital rain in your terminal, written in Rust.

<!-- TODO: screenshot / demo gif -->

## Features

- Multiple character sets (katakana, ASCII, combined), switchable at runtime
- Configurable frame rate (1–60 FPS), adjustable at runtime
- True 24-bit RGB color (consistent across terminal themes)
- Dynamic terminal resize handling
- macOS screensaver (via FFI + Swift)
- Linux GTK4 GUI app with fullscreen and font zoom
- macOS standalone GUI app with fullscreen and font zoom
- Cross-platform screensaver support planned (Linux, Windows)

## Installation

```sh
cargo install --path rsmatrix-cli
```

## Usage

```sh
rsmatrix
```

### Options

| Flag | Description |
|------|-------------|
| `-a`, `--ascii` | Use ASCII/alphanumeric characters only |
| `-k`, `--kana` | Use Japanese half-width katakana only |
| `--fps <N>` | Target frames per second, 1–60 (default: 25) |

### Runtime Keys

| Key | Action |
|-----|--------|
| `q`, `Ctrl+C` | Quit |
| `c` | Clear screen |
| `a` | ASCII only |
| `k` | Katakana only |
| `b` | Combined (kana + ASCII) |
| `+` | Increase FPS |
| `-` | Decrease FPS |
| `=` | Reset FPS to default |
| `Ctrl+L` | Full redraw |

## Linux GTK4 GUI App

Requires GTK4 development libraries:

```sh
# Fedora
sudo dnf install gtk4-devel

# Debian/Ubuntu
sudo apt install libgtk-4-dev
```

Run:

```sh
cargo run -p rsmatrix-gtk
cargo run -p rsmatrix-gtk -- --fullscreen
```

Options: `-a`/`--ascii`, `-k`/`--kana`, `-f`/`--fullscreen`.

| Key | Action |
|-----|--------|
| `q` | Quit |
| `c` | Clear screen |
| `a` | ASCII only |
| `k` | Katakana only |
| `b` | Combined (kana + ASCII) |
| `F11` | Toggle fullscreen |
| `Ctrl+=`/`Ctrl+-` | Font zoom in/out |
| `Ctrl+0` | Reset font size |

## macOS App

Build and run the standalone GUI app:

```sh
make app
make run-app
```

Supports `-a`/`--ascii`, `-k`/`--kana`, `-f`/`--fullscreen` flags. Runtime keys: `a`/`k`/`b` charset, `f` fullscreen, `+`/`-`/`0` font zoom, `c` clear, `q` quit.

## macOS Screensaver

Build and install the screensaver bundle:

```sh
make saver
make install-saver
```

Then open **System Settings > Screen Saver** to select MatrixSaver. Click **Options…** to configure character set and frame rate.

## Project Structure

| Crate | Purpose |
|-------|---------|
| `rsmatrix-core` | Simulation engine (charset, column/stream logic) |
| `rsmatrix-cli` | Terminal UI |
| `rsmatrix-ffi` | C FFI layer for Swift integration |
| `rsmatrix-gtk` | Linux GTK4 GUI app (Pango + Cairo rendering) |
| `macos/` | macOS native code (screensaver + standalone app) |

## Acknowledgments

Based on [gomatrix](https://github.com/GeertJohan/gomatrix) by Geert-Johan Riemer.

## License

[BSD 2-Clause](LICENSE)
