use crate::charset::random_char;
use rand::Rng;

/// RGB color constants matching the terminal version.
const COLOR_GREEN: (u8, u8, u8) = (0, 0xAA, 0);
const COLOR_LIME: (u8, u8, u8) = (0x55, 0xFF, 0x55);
const COLOR_SILVER: (u8, u8, u8) = (0xAA, 0xAA, 0xAA);
const COLOR_WHITE: (u8, u8, u8) = (0xFF, 0xFF, 0xFF);

/// A single cell in the output grid, exposed via FFI.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Cell {
    pub codepoint: u32,
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Cell {
    fn blank() -> Self {
        Self {
            codepoint: ' ' as u32,
            r: 0,
            g: 0,
            b: 0,
        }
    }
}

/// A single falling stream of characters.
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

/// Column spawn state machine.
enum SpawnState {
    /// Waiting for a stream to signal that its tail has started.
    Idle,
    /// Counting down before spawning a new stream.
    Delaying { remaining_ms: i32 },
}

/// A column that manages its streams and spawn timing.
struct Column {
    streams: Vec<Stream>,
    spawn_state: SpawnState,
}

/// Tick-based simulation engine for the Matrix digital rain effect.
pub struct Simulation {
    width: u32,
    height: u32,
    columns: Vec<Column>,
    grid: Vec<Cell>,
}

impl Simulation {
    /// Create a new simulation with the given grid dimensions.
    pub fn new(width: u32, height: u32) -> Self {
        let mut rng = rand::thread_rng();
        let mut columns = Vec::with_capacity(width as usize);

        for _ in 0..width {
            let delay = rng.gen_range(0..9000);
            columns.push(Column {
                streams: Vec::new(),
                spawn_state: SpawnState::Delaying {
                    remaining_ms: delay,
                },
            });
        }

        let grid_size = (width as usize) * (height as usize);
        Simulation {
            width,
            height,
            columns,
            grid: vec![Cell::blank(); grid_size],
        }
    }

    /// Advance the simulation by `delta_ms` milliseconds.
    pub fn tick(&mut self, delta_ms: u32) {
        let delta_ms = delta_ms.min(1000);
        let mut rng = rand::thread_rng();
        let height = self.height as i32;
        let width = self.width as usize;
        let max_streams = 1 + (self.height as usize) / 10;

        let grid = &mut self.grid;
        let columns = &mut self.columns;

        for col_idx in 0..columns.len() {
            let column = &mut columns[col_idx];

            // Process spawn delay
            match &mut column.spawn_state {
                SpawnState::Delaying { remaining_ms } => {
                    *remaining_ms -= delta_ms as i32;
                    if *remaining_ms <= 0 {
                        if column.streams.len() < max_streams {
                            let speed = 30 + rng.gen_range(0..110u32);
                            let length = 10 + rng.gen_range(0..8i32);
                            column.streams.push(Stream {
                                speed_ms: speed,
                                length,
                                head_pos: 0,
                                tail_pos: 0,
                                head_done: false,
                                tail_signaled: false,
                                last_char: ' ',
                                accumulated_ms: 0,
                            });
                        }
                        column.spawn_state = SpawnState::Idle;
                    }
                }
                SpawnState::Idle => {}
            }

            // Process each stream
            let mut signal_new_stream = false;

            column.streams.retain_mut(|stream| {
                stream.accumulated_ms += delta_ms;

                while stream.accumulated_ms >= stream.speed_ms {
                    stream.accumulated_ms -= stream.speed_ms;

                    // Head advancement
                    if !stream.head_done && stream.head_pos <= height {
                        let new_char = random_char(&mut rng);

                        // Re-render previous head position with mid-stream color
                        let prev_row = stream.head_pos - 1;
                        if prev_row >= 0 && prev_row < height {
                            let (r, g, b) = if rng.gen_range(0..100) < 66 {
                                COLOR_GREEN
                            } else {
                                COLOR_LIME
                            };
                            let idx = (prev_row as usize) * width + col_idx;
                            grid[idx] = Cell {
                                codepoint: stream.last_char as u32,
                                r,
                                g,
                                b,
                            };
                        }

                        // Render current head position with bright color
                        if stream.head_pos >= 0 && stream.head_pos < height {
                            let (r, g, b) = if rng.gen_range(0..100) < 33 {
                                COLOR_SILVER
                            } else {
                                COLOR_WHITE
                            };
                            let idx = (stream.head_pos as usize) * width + col_idx;
                            grid[idx] = Cell {
                                codepoint: new_char as u32,
                                r,
                                g,
                                b,
                            };
                        }

                        stream.last_char = new_char;
                        stream.head_pos += 1;
                    } else {
                        stream.head_done = true;
                    }

                    // Tail advancement
                    if stream.tail_pos > 0 || stream.head_pos >= stream.length {
                        if !stream.tail_signaled {
                            stream.tail_signaled = true;
                            signal_new_stream = true;
                        }

                        if stream.tail_pos < height {
                            let idx = (stream.tail_pos as usize) * width + col_idx;
                            grid[idx] = Cell::blank();
                            stream.tail_pos += 1;
                        } else {
                            return false; // Stream complete, remove
                        }
                    }
                }

                true // Keep stream
            });

            // Handle new stream signal
            if signal_new_stream {
                if matches!(column.spawn_state, SpawnState::Idle) {
                    let delay = rng.gen_range(0..9000);
                    column.spawn_state = SpawnState::Delaying {
                        remaining_ms: delay,
                    };
                }
            }
        }
    }

    /// Resize the simulation grid. Clears all streams and resets columns.
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;

        let grid_size = (width as usize) * (height as usize);
        self.grid = vec![Cell::blank(); grid_size];

        let mut rng = rand::thread_rng();
        let new_len = width as usize;

        self.columns.truncate(new_len);
        while self.columns.len() < new_len {
            let delay = rng.gen_range(0..9000);
            self.columns.push(Column {
                streams: Vec::new(),
                spawn_state: SpawnState::Delaying {
                    remaining_ms: delay,
                },
            });
        }

        // Reset existing columns
        for column in &mut self.columns {
            column.streams.clear();
            let delay = rng.gen_range(0..9000);
            column.spawn_state = SpawnState::Delaying {
                remaining_ms: delay,
            };
        }
    }

    /// Get the grid cells as a slice.
    pub fn grid(&self) -> &[Cell] {
        &self.grid
    }

    /// Get the grid width.
    pub fn width(&self) -> u32 {
        self.width
    }

    /// Get the grid height.
    pub fn height(&self) -> u32 {
        self.height
    }
}
