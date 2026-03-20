use crate::charset::random_char;
use crate::screen::{self, SharedScreen};
use crate::types::SharedSizes;
use crossbeam_channel::{Receiver, select};
use rand::Rng;
use std::sync::Mutex;
use std::time::Duration;

/// A single falling stream of characters in a column.
pub struct Stream {
    pub column: u16,
    pub speed: u64,   // milliseconds per tick
    pub length: i32,  // max visible chars before tail starts
}

impl Stream {
    /// Run the stream worker. Blocks until the stream finishes or is stopped.
    pub fn run(
        &self,
        screen: &SharedScreen,
        sizes: &SharedSizes,
        new_stream_signal: &crossbeam_channel::Sender<bool>,
        stop_rx: &Receiver<bool>,
    ) {
        let mut rng = rand::thread_rng();
        let tick_duration = Duration::from_millis(self.speed);

        let mut head_pos: i32 = 0;
        let mut tail_pos: i32 = 0;
        let mut head_done = false;
        let mut last_char: char = ' ';
        let mut tail_signaled = false;

        loop {
            select! {
                recv(stop_rx) -> _ => {
                    return;
                }
                default(tick_duration) => {
                    let screen_height = {
                        let s = sizes.read().unwrap();
                        s.height as i32
                    };

                    // Head advancement
                    if !head_done && head_pos <= screen_height {
                        let new_char = random_char(&mut rng);

                        // Re-render previous head position with mid-stream color
                        let prev_row = head_pos - 1;
                        if prev_row >= 0 && prev_row < screen_height {
                            let fg = if rng.gen_range(0..100) < 66 {
                                screen::GREEN
                            } else {
                                screen::LIME
                            };
                            let mut buf = screen.lock().unwrap();
                            buf.set_cell(self.column, prev_row as u16, fg, screen::BLACK, last_char);
                        }

                        // Render current head position with head color
                        if head_pos >= 0 && head_pos < screen_height {
                            let fg = if rng.gen_range(0..100) < 33 {
                                screen::SILVER
                            } else {
                                screen::WHITE
                            };
                            let mut buf = screen.lock().unwrap();
                            buf.set_cell(self.column, head_pos as u16, fg, screen::BLACK, new_char);
                        }

                        last_char = new_char;
                        head_pos += 1;
                    } else {
                        head_done = true;
                    }

                    // Tail advancement
                    if tail_pos > 0 || head_pos >= self.length {
                        if !tail_signaled {
                            // First time tail moves — signal new stream
                            tail_signaled = true;
                            let _ = new_stream_signal.try_send(true);
                        }

                        if tail_pos < screen_height {
                            let mut buf = screen.lock().unwrap();
                            buf.set_cell(self.column, tail_pos as u16, screen::BLACK, screen::BLACK, ' ');
                            tail_pos += 1;
                        } else {
                            // Stream complete
                            return;
                        }
                    }
                }
            }
        }
    }
}

/// Tracks active streams in a column (for mutex-protected removal).
pub struct StreamSet {
    pub count: Mutex<usize>,
}

impl StreamSet {
    pub fn new() -> Self {
        Self {
            count: Mutex::new(0),
        }
    }

    pub fn increment(&self) {
        let mut c = self.count.lock().unwrap();
        *c += 1;
    }

    pub fn decrement(&self) {
        let mut c = self.count.lock().unwrap();
        *c = c.saturating_sub(1);
    }

    pub fn get(&self) -> usize {
        *self.count.lock().unwrap()
    }
}
