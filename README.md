# rsmatrix

Matrix digital rain in your terminal, written in Rust.

<!-- TODO: screenshot / demo gif -->

## Features

- Multiple character sets (katakana, ASCII, combined), switchable at runtime
- Configurable frame rate (1–60 FPS), adjustable at runtime
- True 24-bit RGB color (consistent across terminal themes)
- Dynamic terminal resize handling
- macOS screensaver (via FFI + Swift)
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
| `q` | Quit |
| `c` | Cycle character set |
| `k` | Katakana only |
| `b` | ASCII only |
| `+` | Increase FPS |
| `-` | Decrease FPS |
| `=` | Reset FPS to default |

## macOS Screensaver

Build and install the screensaver bundle:

```sh
make saver
make install
```

Then open **System Settings > Screen Saver** to select MatrixSaver.

## Project Structure

| Crate | Purpose |
|-------|---------|
| `rsmatrix-core` | Simulation engine (charset, column/stream logic) |
| `rsmatrix-cli` | Terminal UI |
| `rsmatrix-ffi` | C FFI layer for Swift integration |
| `screensavers/` | Platform-specific screensavers (macOS, Linux, Windows) |

## Acknowledgments

Based on [gomatrix](https://github.com/GeertJohan/gomatrix) by Geert-Johan Riemer.

## License

[BSD 2-Clause](LICENSE)
