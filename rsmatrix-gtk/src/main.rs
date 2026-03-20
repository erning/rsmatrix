mod renderer;

use clap::Parser;
use gtk4::gdk;
use gtk4::glib;
use gtk4::prelude::*;
use rsmatrix_core::charset;
use rsmatrix_core::simulation::Simulation;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Instant;

use renderer::Renderer;

const DEFAULT_FONT_SIZE: i32 = 14;
const MIN_FONT_SIZE: i32 = 6;
const MAX_FONT_SIZE: i32 = 28;

#[derive(Parser)]
#[command(name = "rsmatrix-gtk", about = "Matrix digital rain GTK4 GUI app")]
struct Cli {
    /// Use ASCII/alphanumeric characters only
    #[arg(short = 'a', long = "ascii")]
    ascii: bool,

    /// Use Japanese half-width katakana only
    #[arg(short = 'k', long = "kana")]
    kana: bool,

    /// Start in fullscreen mode
    #[arg(short = 'f', long = "fullscreen")]
    fullscreen: bool,
}

struct AppState {
    sim: Simulation,
    renderer: Renderer,
    font_size: i32,
    last_frame: Instant,
    last_grid_w: u32,
    last_grid_h: u32,
}

fn main() {
    let cli = Cli::try_parse().unwrap_or_else(|e| e.exit());

    if cli.ascii {
        charset::set_charset(charset::CHARSET_ASCII);
    } else if cli.kana {
        charset::set_charset(charset::CHARSET_KANA);
    } else {
        charset::set_charset(charset::CHARSET_COMBINED);
    }

    let start_fullscreen = cli.fullscreen;

    let app = gtk4::Application::builder()
        .application_id("com.rsmatrix.gtk")
        .build();

    app.connect_activate(move |app| build_ui(app, start_fullscreen));
    app.run_with_args::<&str>(&[]);
}

fn build_ui(app: &gtk4::Application, start_fullscreen: bool) {
    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .title("Matrix")
        .default_width(800)
        .default_height(600)
        .decorated(false)
        .build();

    if start_fullscreen {
        window.fullscreen();
    }

    let drawing_area = gtk4::DrawingArea::new();
    drawing_area.set_hexpand(true);
    drawing_area.set_vexpand(true);
    window.set_child(Some(&drawing_area));

    // Apply black background via CSS
    let css_provider = gtk4::CssProvider::new();
    css_provider.load_from_string("window, drawingarea { background-color: black; }");
    gtk4::style_context_add_provider_for_display(
        &gdk::Display::default().expect("no display"),
        &css_provider,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    let renderer = Renderer::new(DEFAULT_FONT_SIZE);
    let sim = Simulation::new(1, 1); // will resize on first draw

    let state = Rc::new(RefCell::new(AppState {
        sim,
        renderer,
        font_size: DEFAULT_FONT_SIZE,
        last_frame: Instant::now(),
        last_grid_w: 0,
        last_grid_h: 0,
    }));

    // Draw function
    let state_draw = Rc::clone(&state);
    drawing_area.set_draw_func(move |_da, cr, width, height| {
        let mut st = state_draw.borrow_mut();

        let grid_w = (width as f64 / st.renderer.cell_width).max(1.0) as u32;
        let grid_h = (height as f64 / st.renderer.cell_height).max(1.0) as u32;

        if grid_w != st.last_grid_w || grid_h != st.last_grid_h {
            st.sim.resize(grid_w, grid_h);
            st.last_grid_w = grid_w;
            st.last_grid_h = grid_h;
        }

        let now = Instant::now();
        let delta_ms = now.duration_since(st.last_frame).as_millis() as u32;
        st.last_frame = now;

        st.sim.tick(delta_ms);
        let grid = st.sim.grid();
        st.renderer.render(cr, grid, grid_w, grid_h);
    });

    // Frame clock: use tick callback for vsync-driven animation
    let state_tick = Rc::clone(&state);
    let da = drawing_area.clone();
    drawing_area.add_tick_callback(move |_widget, _clock| {
        // Just trigger redraw each frame
        let _ = state_tick.borrow(); // ensure state exists
        da.queue_draw();
        glib::ControlFlow::Continue
    });

    // Keyboard controls
    let key_controller = gtk4::EventControllerKey::new();
    let state_key = Rc::clone(&state);
    let win_ref = window.clone();
    key_controller.connect_key_pressed(move |_ctrl, keyval, _keycode, modifier| {
        let ctrl = modifier.contains(gdk::ModifierType::CONTROL_MASK);

        match keyval {
            v if v == gdk::Key::q => {
                win_ref.close();
                glib::Propagation::Stop
            }
            v if v == gdk::Key::c && !ctrl => {
                state_key.borrow_mut().sim.clear();
                glib::Propagation::Stop
            }
            v if v == gdk::Key::k => {
                charset::set_charset(charset::CHARSET_KANA);
                glib::Propagation::Stop
            }
            v if v == gdk::Key::b => {
                charset::set_charset(charset::CHARSET_COMBINED);
                glib::Propagation::Stop
            }
            v if v == gdk::Key::a => {
                charset::set_charset(charset::CHARSET_ASCII);
                glib::Propagation::Stop
            }
            v if v == gdk::Key::Escape => {
                if win_ref.is_fullscreen() {
                    win_ref.unfullscreen();
                }
                glib::Propagation::Stop
            }
            v if v == gdk::Key::f || v == gdk::Key::F11 => {
                if win_ref.is_fullscreen() {
                    win_ref.unfullscreen();
                } else {
                    win_ref.fullscreen();
                }
                glib::Propagation::Stop
            }
            v if (v == gdk::Key::equal || v == gdk::Key::plus) && ctrl => {
                let mut st = state_key.borrow_mut();
                if st.font_size < MAX_FONT_SIZE {
                    st.font_size += 1;
                    let size = st.font_size;
                    st.renderer.set_font_size(size);
                    st.last_grid_w = 0; // force resize
                }
                glib::Propagation::Stop
            }
            v if v == gdk::Key::minus && ctrl => {
                let mut st = state_key.borrow_mut();
                if st.font_size > MIN_FONT_SIZE {
                    st.font_size -= 1;
                    let size = st.font_size;
                    st.renderer.set_font_size(size);
                    st.last_grid_w = 0;
                }
                glib::Propagation::Stop
            }
            v if v == gdk::Key::_0 && ctrl => {
                let mut st = state_key.borrow_mut();
                st.font_size = DEFAULT_FONT_SIZE;
                st.renderer.set_font_size(DEFAULT_FONT_SIZE);
                st.last_grid_w = 0;
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    window.add_controller(key_controller);

    // Hide cursor over the drawing area
    drawing_area.set_cursor(gdk::Cursor::from_name("none", None).as_ref());

    window.present();
}
