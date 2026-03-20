/// Grid dimensions and derived limits.
#[derive(Clone, Copy, Debug)]
pub struct Sizes {
    pub width: u32,
    pub height: u32,
    pub max_streams_per_column: usize,
}

impl Sizes {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            max_streams_per_column: 1 + (height as usize) / 10,
        }
    }
}
