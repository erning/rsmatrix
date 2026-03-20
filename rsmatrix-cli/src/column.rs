use crate::screen::SharedScreen;
use crate::stream::{Stream, StreamSet};
use crate::types::SharedSizes;
use crossbeam_channel::{Receiver, Sender, select, bounded};
use rand::Rng;
use std::collections::HashMap;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Handle to a running column worker.
struct ColumnHandle {
    stop_tx: Sender<bool>,
    /// Kept alive to prevent the channel from closing; streams use cloned senders.
    _new_stream_tx: Sender<bool>,
}

/// Manages all column workers, handling resize events.
pub fn run_column_manager(
    sizes_rx: Receiver<()>,
    shared_sizes: SharedSizes,
    screen: SharedScreen,
    stop_rx: Receiver<bool>,
) {
    let mut columns: HashMap<u16, ColumnHandle> = HashMap::new();
    let mut last_width: u16 = 0;

    loop {
        select! {
            recv(stop_rx) -> _ => {
                for (_, handle) in columns.drain() {
                    let _ = handle.stop_tx.send(true);
                }
                return;
            }
            recv(sizes_rx) -> _ => {
                let new_sizes = *shared_sizes.read().unwrap();
                let new_width = new_sizes.width;
                let diff = new_width as i32 - last_width as i32;

                if diff == 0 {
                    continue;
                }

                if diff > 0 {
                    for col in last_width..new_width {
                        let (new_stream_tx, new_stream_rx) = bounded::<bool>(1);
                        let (stop_tx, col_stop_rx) = bounded::<bool>(1);

                        let scr = screen.clone();
                        let sz = shared_sizes.clone();
                        let ns_tx = new_stream_tx.clone();

                        thread::Builder::new()
                            .name(format!("col-{}", col))
                            .spawn(move || {
                                run_column_worker(col, scr, sz, col_stop_rx, new_stream_rx, ns_tx);
                            })
                            .expect("failed to spawn column worker thread");

                        // Trigger first stream
                        let _ = new_stream_tx.try_send(true);

                        columns.insert(col, ColumnHandle { stop_tx, _new_stream_tx: new_stream_tx });
                    }
                } else {
                    // Fix Go's off-by-one: iterate all columns from last_width-1 down to new_width (inclusive)
                    for col in (new_width..last_width).rev() {
                        if let Some(handle) = columns.remove(&col) {
                            let _ = handle.stop_tx.send(true);
                        }
                    }
                }

                last_width = new_width;
            }
        }
    }
}

/// Runs a single column worker managing stream lifecycle.
fn run_column_worker(
    column: u16,
    screen: SharedScreen,
    sizes: SharedSizes,
    stop_rx: Receiver<bool>,
    new_stream_rx: Receiver<bool>,
    new_stream_tx: Sender<bool>,
) {
    let stream_set = Arc::new(StreamSet::new());
    let mut stream_stop_txs: Vec<Sender<bool>> = Vec::new();

    loop {
        select! {
            recv(stop_rx) -> _ => {
                for tx in stream_stop_txs.drain(..) {
                    let _ = tx.try_send(true);
                }
                return;
            }
            recv(new_stream_rx) -> _ => {
                // Check stream limit
                let max = sizes.read().unwrap().max_streams_per_column;
                if stream_set.get() >= max {
                    continue;
                }

                // Random spawn delay (0-8999 ms)
                let delay = {
                    let mut rng = rand::thread_rng();
                    rng.gen_range(0..9000) as u64
                };

                // Wait for spawn delay, but remain responsive to stop
                let delay_done = crossbeam_channel::after(Duration::from_millis(delay));
                select! {
                    recv(stop_rx) -> _ => {
                        for tx in stream_stop_txs.drain(..) {
                            let _ = tx.try_send(true);
                        }
                        return;
                    }
                    recv(delay_done) -> _ => {}
                }

                // Recheck limit after delay
                let max = sizes.read().unwrap().max_streams_per_column;
                if stream_set.get() >= max {
                    continue;
                }

                // Create stream with randomized parameters
                let mut rng = rand::thread_rng();
                let stream = Stream {
                    column,
                    speed: 30 + rng.gen_range(0..110),
                    length: 10 + rng.gen_range(0..8),
                };

                let (stream_stop_tx, stream_stop_rx) = bounded::<bool>(0);
                stream_stop_txs.push(stream_stop_tx);

                let ss = stream_set.clone();
                ss.increment();

                let scr = screen.clone();
                let sz = sizes.clone();
                let ns_tx = new_stream_tx.clone();

                thread::Builder::new()
                    .name(format!("stream-{}", column))
                    .stack_size(64 * 1024)
                    .spawn(move || {
                        stream.run(&scr, &sz, &ns_tx, &stream_stop_rx);
                        ss.decrement();
                    })
                    .expect("failed to spawn stream thread");
            }
        }
    }
}
