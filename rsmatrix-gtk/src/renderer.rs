use gtk4::pango;
use gtk4::cairo;
use pangocairo::functions as pc;
use rsmatrix_core::simulation::Cell;

const COLOR_SLOTS: [(u8, u8, u8); 4] = [
    (255, 255, 255), // white
    (170, 170, 170), // silver
    (85, 255, 85),   // lime
    (0, 170, 0),     // green
];

pub struct Renderer {
    font_desc: pango::FontDescription,
    pub cell_width: f64,
    pub cell_height: f64,
    color_slots: [Vec<(u32, u32, char)>; 4],
}

impl Renderer {
    pub fn new(font_size: i32) -> Self {
        let mut font_desc = pango::FontDescription::from_string("Monospace");
        font_desc.set_size(font_size * pango::SCALE);

        let mut renderer = Self {
            font_desc,
            cell_width: 0.0,
            cell_height: 0.0,
            color_slots: [Vec::new(), Vec::new(), Vec::new(), Vec::new()],
        };
        renderer.measure_cell();
        renderer
    }

    pub fn set_font_size(&mut self, size: i32) {
        self.font_desc.set_size(size * pango::SCALE);
        self.measure_cell();
    }

    fn measure_cell(&mut self) {
        // Use a temporary surface to measure text extents
        let surface = cairo::ImageSurface::create(cairo::Format::ARgb32, 1, 1)
            .expect("failed to create measurement surface");
        let cr = cairo::Context::new(&surface).expect("failed to create cairo context");

        let layout = pc::create_layout(&cr);
        layout.set_font_description(Some(&self.font_desc));
        layout.set_text("W");

        let (ink_rect, _logical_rect) = layout.pixel_extents();
        // Use logical size for consistent spacing, but ensure minimum from ink
        let (_log_w, log_h) = layout.pixel_size();

        self.cell_width = ink_rect.width().max(8) as f64;
        self.cell_height = log_h.max(ink_rect.height()).max(10) as f64;
    }

    pub fn render(&mut self, cr: &cairo::Context, grid: &[Cell], grid_w: u32, grid_h: u32) {
        // Clear to black
        cr.set_source_rgb(0.0, 0.0, 0.0);
        let _ = cr.paint();

        let layout = pc::create_layout(cr);
        layout.set_font_description(Some(&self.font_desc));

        // Clear slots (preserves capacity)
        for slot in &mut self.color_slots {
            slot.clear();
        }

        for row in 0..grid_h {
            for col in 0..grid_w {
                let cell = &grid[(row * grid_w + col) as usize];
                if cell.codepoint == ' ' as u32 || (cell.r == 0 && cell.g == 0 && cell.b == 0) {
                    continue;
                }
                let ch = match char::from_u32(cell.codepoint) {
                    Some(c) => c,
                    None => continue,
                };

                let slot_idx = match (cell.r, cell.g, cell.b) {
                    (255, 255, 255) => 0,
                    (170, 170, 170) => 1,
                    (85, 255, 85) => 2,
                    (0, 170, 0) => 3,
                    _ => continue,
                };
                self.color_slots[slot_idx].push((col, row, ch));
            }
        }

        let mut buf = [0u8; 4];
        for (i, slot) in self.color_slots.iter().enumerate() {
            if slot.is_empty() {
                continue;
            }
            let (r, g, b) = COLOR_SLOTS[i];
            cr.set_source_rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
            for &(col, row, ch) in slot {
                cr.move_to(col as f64 * self.cell_width, row as f64 * self.cell_height);
                layout.set_text(ch.encode_utf8(&mut buf));
                pc::show_layout(cr, &layout);
            }
        }
    }
}
