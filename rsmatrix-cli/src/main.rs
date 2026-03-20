mod screen;

use clap::Parser;
use crossterm::{
    cursor, event,
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use rsmatrix_core::charset;
use rsmatrix_core::simulation::Simulation;
use std::io;
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use screen::ScreenBuffer;

/// RAII guard that restores terminal state on drop (including panics).
struct TerminalGuard;

impl TerminalGuard {
    fn init() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        io::stdout().execute(EnterAlternateScreen)?;
        io::stdout().execute(cursor::Hide)?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = io::stdout().execute(cursor::Show);
        let _ = io::stdout().execute(LeaveAlternateScreen);
        let _ = terminal::disable_raw_mode();
    }
}

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
    let cli = Cli::try_parse().unwrap_or_else(|e| e.exit());

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
        charset::set_charset(charset::CHARSET_KANA);
    } else {
        charset::set_charset(charset::CHARSET_COMBINED);
    }

    // Initialize terminal (RAII guard ensures cleanup on panic/exit)
    let _guard = TerminalGuard::init().expect("failed to initialize terminal");
    let mut stdout = io::stdout();

    let (width, height) = terminal::size().expect("failed to get terminal size");

    // Create simulation and screen buffer
    let mut sim = Simulation::new(width as u32, height as u32);
    let mut screen_buf = ScreenBuffer::new(width, height);
    let initial_fps = cli.fps;
    let mut fps = cli.fps;

    let fps_micros = 1_000_000u64 / cli.fps as u64;
    println!("fps sleep time: {}", format_duration_micros(fps_micros));

    // Signal handler for external SIGINT
    let sig_flag = Arc::new(AtomicBool::new(false));
    let _ = signal_hook::flag::register(signal_hook::consts::SIGINT, sig_flag.clone());

    let mut last_tick = Instant::now();

    // Main loop
    loop {
        let frame_duration = Duration::from_micros(1_000_000 / fps as u64);

        // Poll for events or timeout at frame rate
        if event::poll(frame_duration).unwrap_or(false) {
            if let Ok(ev) = event::read() {
                match ev {
                    event::Event::Key(key_event) => {
                        if key_event.kind != event::KeyEventKind::Press {
                            continue;
                        }
                        match key_event.code {
                            event::KeyCode::Char('c')
                                if key_event
                                    .modifiers
                                    .contains(event::KeyModifiers::CONTROL) =>
                            {
                                break;
                            }
                            event::KeyCode::Char('z')
                                if key_event
                                    .modifiers
                                    .contains(event::KeyModifiers::CONTROL) =>
                            {
                                break;
                            }
                            event::KeyCode::Char('l')
                                if key_event
                                    .modifiers
                                    .contains(event::KeyModifiers::CONTROL) =>
                            {
                                screen_buf.request_full_redraw();
                            }
                            event::KeyCode::Char('q') => break,
                            event::KeyCode::Char('c') => {
                                sim.clear();
                                screen_buf.clear();
                            }
                            event::KeyCode::Char('k') => {
                                charset::set_charset(charset::CHARSET_KANA);
                            }
                            event::KeyCode::Char('b') => {
                                charset::set_charset(charset::CHARSET_COMBINED);
                            }
                            event::KeyCode::Char('+') => {
                                if fps < 60 {
                                    fps += 1;
                                }
                            }
                            event::KeyCode::Char('-') => {
                                if fps > 1 {
                                    fps -= 1;
                                }
                            }
                            event::KeyCode::Char('=') => {
                                fps = initial_fps;
                            }
                            _ => {}
                        }
                    }
                    event::Event::Resize(w, h) => {
                        sim.resize(w as u32, h as u32);
                        screen_buf.resize(w, h);
                    }
                    _ => {}
                }
            }
        }

        // Check SIGINT
        if sig_flag.load(Ordering::Relaxed) {
            break;
        }

        // Compute delta and tick simulation
        let now = Instant::now();
        let delta = now.duration_since(last_tick);
        last_tick = now;
        let delta_ms = delta.as_millis() as u32;

        sim.tick(delta_ms);

        // Map simulation grid to screen buffer
        let grid = sim.grid();
        let sim_w = sim.width() as u16;
        let sim_h = sim.height() as u16;
        for row in 0..sim_h {
            for col in 0..sim_w {
                let idx = (row as usize) * (sim_w as usize) + (col as usize);
                let cell = &grid[idx];
                let ch = char::from_u32(cell.codepoint).unwrap_or(' ');
                let fg = crossterm::style::Color::Rgb {
                    r: cell.r,
                    g: cell.g,
                    b: cell.b,
                };
                screen_buf.set_cell(col, row, fg, screen::BLACK, ch);
            }
        }

        // Flush to terminal
        let _ = screen_buf.flush(&mut stdout);
    }

    drop(_guard);
    println!("Thank you for connecting with Morpheus' Matrix API v4.2. Have a nice day!");
}

/// Format microseconds as a human-readable duration string matching Go's time.Duration.String().
fn format_duration_micros(us: u64) -> String {
    if us >= 1_000_000 && us.is_multiple_of(1_000_000) {
        format!("{}s", us / 1_000_000)
    } else if us >= 1_000 && us.is_multiple_of(1_000) {
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
