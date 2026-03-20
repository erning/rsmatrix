use std::sync::{Arc, RwLock};

/// Terminal dimensions and derived limits, shared across threads.
#[derive(Clone, Copy, Debug)]
pub struct Sizes {
    pub width: u16,
    pub height: u16,
    pub max_streams_per_column: usize,
}

impl Sizes {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            max_streams_per_column: 1 + (height as usize) / 10,
        }
    }
}

pub type SharedSizes = Arc<RwLock<Sizes>>;
