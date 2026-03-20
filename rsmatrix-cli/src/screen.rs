use crossterm::style::Color;
use std::io::{self, Write};

/// RGB color constant for background.
pub const BLACK: Color = Color::Rgb { r: 0, g: 0, b: 0 };

#[derive(Clone, Copy)]
struct Cell {
    ch: char,
    fg: Color,
    bg: Color,
    dirty: bool,
}

impl Cell {
    fn blank() -> Self {
        Self {
            ch: ' ',
            fg: BLACK,
            bg: BLACK,
            dirty: false,
        }
    }
}

/// A screen buffer that tracks dirty cells and flushes only changes.
pub struct ScreenBuffer {
    width: u16,
    height: u16,
    cells: Vec<Cell>,
    /// When true, the entire screen needs redrawing.
    full_redraw: bool,
}

impl ScreenBuffer {
    pub fn new(width: u16, height: u16) -> Self {
        let size = (width as usize) * (height as usize);
        Self {
            width,
            height,
            cells: vec![Cell::blank(); size],
            full_redraw: true,
        }
    }

    /// Set a cell. Marks it dirty if changed.
    pub fn set_cell(&mut self, col: u16, row: u16, fg: Color, bg: Color, ch: char) {
        if col >= self.width || row >= self.height {
            return;
        }
        let idx = (row as usize) * (self.width as usize) + (col as usize);
        let cell = &mut self.cells[idx];
        // Always mark dirty on write — streams overwrite frequently with different colors
        cell.ch = ch;
        cell.fg = fg;
        cell.bg = bg;
        cell.dirty = true;
    }

    /// Resize the buffer, clearing all content.
    pub fn resize(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        let size = (width as usize) * (height as usize);
        self.cells = vec![Cell::blank(); size];
        self.full_redraw = true;
    }

    /// Clear the entire buffer.
    pub fn clear(&mut self) {
        for cell in self.cells.iter_mut() {
            cell.ch = ' ';
            cell.fg = BLACK;
            cell.bg = BLACK;
            cell.dirty = true;
        }
        self.full_redraw = true;
    }

    /// Request a full redraw on next flush.
    pub fn request_full_redraw(&mut self) {
        self.full_redraw = true;
    }

    /// Flush dirty cells to the terminal.
    pub fn flush(&mut self, stdout: &mut io::Stdout) -> io::Result<()> {
        use crossterm::{cursor, queue, style};

        let full = self.full_redraw;
        self.full_redraw = false;

        for row in 0..self.height {
            for col in 0..self.width {
                let idx = (row as usize) * (self.width as usize) + (col as usize);
                let cell = &mut self.cells[idx];
                if cell.dirty || full {
                    cell.dirty = false;
                    queue!(
                        stdout,
                        cursor::MoveTo(col, row),
                        style::SetForegroundColor(cell.fg),
                        style::SetBackgroundColor(cell.bg),
                        style::Print(cell.ch)
                    )?;
                }
            }
        }

        stdout.flush()?;
        Ok(())
    }
}
