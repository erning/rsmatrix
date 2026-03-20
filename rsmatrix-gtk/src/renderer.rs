use gtk4::pango;
use gtk4::cairo;
use pangocairo::functions as pc;
use rsmatrix_core::simulation::Cell;

pub struct Renderer {
    font_desc: pango::FontDescription,
    pub cell_width: f64,
    pub cell_height: f64,
}

impl Renderer {
    pub fn new(font_size: i32) -> Self {
        let mut font_desc = pango::FontDescription::from_string("Monospace");
        font_desc.set_size(font_size * pango::SCALE);

        let mut renderer = Self {
            font_desc,
            cell_width: 0.0,
            cell_height: 0.0,
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

    pub fn render(&self, cr: &cairo::Context, grid: &[Cell], grid_w: u32, grid_h: u32) {
        // Clear to black
        cr.set_source_rgb(0.0, 0.0, 0.0);
        let _ = cr.paint();

        let layout = pc::create_layout(cr);
        layout.set_font_description(Some(&self.font_desc));

        // Bucket cells by color to minimize set_source_rgb calls
        // Colors: white (255,255,255), silver (170,170,170), lime (85,255,85), green (0,170,0)
        struct ColorBucket {
            r: f64,
            g: f64,
            b: f64,
            cells: Vec<(u32, u32, char)>, // col, row, character
        }

        let mut buckets: Vec<ColorBucket> = Vec::with_capacity(4);

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
                let r = cell.r as f64 / 255.0;
                let g = cell.g as f64 / 255.0;
                let b = cell.b as f64 / 255.0;

                // Find or create bucket
                let bucket = buckets.iter_mut().find(|bkt| {
                    (bkt.r - r).abs() < 0.01 && (bkt.g - g).abs() < 0.01 && (bkt.b - b).abs() < 0.01
                });
                if let Some(bucket) = bucket {
                    bucket.cells.push((col, row, ch));
                } else {
                    buckets.push(ColorBucket {
                        r,
                        g,
                        b,
                        cells: vec![(col, row, ch)],
                    });
                }
            }
        }

        let mut buf = [0u8; 4];
        for bucket in &buckets {
            cr.set_source_rgb(bucket.r, bucket.g, bucket.b);
            for &(col, row, ch) in &bucket.cells {
                cr.move_to(col as f64 * self.cell_width, row as f64 * self.cell_height);
                layout.set_text(ch.encode_utf8(&mut buf));
                pc::show_layout(cr, &layout);
            }
        }
    }
}
