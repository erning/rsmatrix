mod charset;
mod column;
mod screen;
mod stream;
mod types;

use clap::error::ErrorKind;
use clap::Parser;
use crossbeam_channel::{bounded, select};
use crossterm::{
    cursor, event,
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;
use std::{process, thread};

use charset::{CHARSET_COMBINED, CHARSET_KANA};
use screen::ScreenBuffer;
use types::Sizes;

#[derive(Parser)]
#[command(name = "rsmatrix", about = "Matrix digital rain terminal effect")]
struct Cli {
    /// Use ASCII/alphanumeric characters only
    #[arg(short = 'a', long = "ascii")]
    ascii: bool,

    /// Use Japanese half-width katakana only
    #[arg(short = 'k', long = "kana")]
    kana: bool,

    /// Target frames per second (1-60)
    #[arg(long = "fps", default_value_t = 25)]
    fps: u32,
}

fn main() {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(e) => {
            match e.kind() {
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => {
                    e.exit();
                }
                _ => {
                    let args: Vec<String> = std::env::args().collect();
                    if let Some(arg) = args.iter().skip(1).find(|a| !a.starts_with('-')) {
                        println!("Unknown argument '{}'.", arg);
                    } else {
                        println!("Use --help to view all available options.");
                    }
                    return;
                }
            }
        }
    };

    // Validate FPS
    if cli.fps < 1 || cli.fps > 60 {
        println!("Error: option --fps not within range 1-60");
        process::exit(1);
    }

    println!("Opening connection to The Matrix.. Please stand by..");

    // Set initial character set (--ascii takes precedence)
    if cli.ascii {
        charset::set_charset(charset::CHARSET_ASCII);
    } else if cli.kana {
        charset::set_charset(CHARSET_KANA);
    } else {
        charset::set_charset(CHARSET_COMBINED);
    }

    // Initialize terminal
    let mut stdout = io::stdout();
    terminal::enable_raw_mode().expect("failed to enable raw mode");
    stdout
        .execute(EnterAlternateScreen)
        .expect("failed to enter alternate screen");
    stdout
        .execute(cursor::Hide)
        .expect("failed to hide cursor");

    let (width, height) = terminal::size().expect("failed to get terminal size");

    // Shared state
    let shared_sizes = Arc::new(RwLock::new(Sizes::new(width, height)));
    let screen_buf = Arc::new(std::sync::Mutex::new(ScreenBuffer::new(width, height)));
    let initial_fps = cli.fps;
    let fps = Arc::new(AtomicU64::new(cli.fps as u64));

    let fps_micros = 1_000_000u64 / cli.fps as u64;
    println!("fps sleep time: {}", format_duration_micros(fps_micros));

    // Channels
    let (sizes_tx, sizes_rx) = bounded::<()>(0);
    let (cm_stop_tx, cm_stop_rx) = bounded::<bool>(1);
    let (event_tx, event_rx) = bounded::<event::Event>(0);

    // Signal handler for external SIGINT
    let (sig_tx, sig_rx) = bounded::<()>(1);
    {
        let sig_flag = Arc::new(AtomicBool::new(false));
        let _ = signal_hook::flag::register(signal_hook::consts::SIGINT, sig_flag.clone());
        let tx = sig_tx;
        thread::spawn(move || {
            loop {
                if sig_flag.load(Ordering::Relaxed) {
                    let _ = tx.send(());
                    return;
                }
                thread::sleep(Duration::from_millis(50));
            }
        });
    }

    // Column manager thread
    {
        let sz = shared_sizes.clone();
        let scr = screen_buf.clone();
        thread::Builder::new()
            .name("col-manager".into())
            .spawn(move || {
                column::run_column_manager(sizes_rx, sz, scr, cm_stop_rx);
            })
            .expect("failed to spawn column manager");
    }

    // Send initial sizes
    let _ = sizes_tx.send(());

    // Screen flusher thread
    {
        let scr = screen_buf.clone();
        let fps_ref = fps.clone();
        thread::Builder::new()
            .name("flusher".into())
            .spawn(move || {
                let mut stdout = io::stdout();
                loop {
                    let cur_fps = fps_ref.load(Ordering::Relaxed);
                    if cur_fps == 0 {
                        break;
                    }
                    let sleep_time = Duration::from_micros(1_000_000 / cur_fps);
                    thread::sleep(sleep_time);
                    let mut buf = scr.lock().unwrap();
                    let _ = buf.flush(&mut stdout);
                }
            })
            .expect("failed to spawn flusher");
    }

    // Event poller thread
    thread::Builder::new()
        .name("event-poller".into())
        .spawn(move || loop {
            if let Ok(ev) = event::read() {
                if event_tx.send(ev).is_err() {
                    return;
                }
            }
        })
        .expect("failed to spawn event poller");

    // Main event loop
    'events: loop {
        select! {
            recv(event_rx) -> ev => {
                if let Ok(ev) = ev {
                    match ev {
                        event::Event::Key(key_event) => {
                            if key_event.kind != event::KeyEventKind::Press {
                                continue;
                            }
                            match key_event.code {
                                event::KeyCode::Char('c') if key_event.modifiers.contains(event::KeyModifiers::CONTROL) => {
                                    break 'events;
                                }
                                event::KeyCode::Char('z') if key_event.modifiers.contains(event::KeyModifiers::CONTROL) => {
                                    break 'events;
                                }
                                event::KeyCode::Char('l') if key_event.modifiers.contains(event::KeyModifiers::CONTROL) => {
                                    let mut buf = screen_buf.lock().unwrap();
                                    buf.request_full_redraw();
                                }
                                event::KeyCode::Char('q') => break 'events,
                                event::KeyCode::Char('c') => {
                                    let mut buf = screen_buf.lock().unwrap();
                                    buf.clear();
                                }
                                event::KeyCode::Char('k') => {
                                    charset::set_charset(CHARSET_KANA);
                                }
                                event::KeyCode::Char('b') => {
                                    charset::set_charset(CHARSET_COMBINED);
                                }
                                event::KeyCode::Char('+') => {
                                    let cur = fps.load(Ordering::Relaxed);
                                    if cur < 60 {
                                        fps.store(cur + 1, Ordering::Relaxed);
                                    }
                                }
                                event::KeyCode::Char('-') => {
                                    let cur = fps.load(Ordering::Relaxed);
                                    if cur > 1 {
                                        fps.store(cur - 1, Ordering::Relaxed);
                                    }
                                }
                                event::KeyCode::Char('=') => {
                                    fps.store(initial_fps as u64, Ordering::Relaxed);
                                }
                                _ => {}
                            }
                        }
                        event::Event::Resize(w, h) => {
                            {
                                let mut s = shared_sizes.write().unwrap();
                                *s = Sizes::new(w, h);
                            }
                            {
                                let mut buf = screen_buf.lock().unwrap();
                                buf.resize(w, h);
                            }
                            let _ = sizes_tx.send(());
                        }
                        _ => {}
                    }
                }
            }
            recv(sig_rx) -> _ => {
                break 'events;
            }
        }
    }

    // Shutdown
    fps.store(0, Ordering::Relaxed);
    let _ = cm_stop_tx.send(true);

    // Restore terminal
    let mut stdout = io::stdout();
    let _ = stdout.execute(cursor::Show);
    let _ = stdout.execute(LeaveAlternateScreen);
    let _ = terminal::disable_raw_mode();

    println!("Thank you for connecting with Morpheus' Matrix API v4.2. Have a nice day!");
}

/// Format microseconds as a human-readable duration string matching Go's time.Duration.String().
fn format_duration_micros(us: u64) -> String {
    if us >= 1_000_000 && us % 1_000_000 == 0 {
        format!("{}s", us / 1_000_000)
    } else if us >= 1_000 && us % 1_000 == 0 {
        format!("{}ms", us / 1_000)
    } else if us >= 1_000 {
        let ms = us as f64 / 1_000.0;
        // Trim trailing zeros after decimal point
        let s = format!("{:.3}", ms);
        let s = s.trim_end_matches('0');
        let s = s.trim_end_matches('.');
        format!("{}ms", s)
    } else {
        format!("{}µs", us)
    }
}
