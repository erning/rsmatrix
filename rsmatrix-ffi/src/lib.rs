use rsmatrix_core::simulation::{Cell, Simulation};

#[no_mangle]
pub extern "C" fn rsmatrix_create(width: u32, height: u32) -> *mut Simulation {
    let sim = Box::new(Simulation::new(width, height));
    Box::into_raw(sim)
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`, and must not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_destroy(sim: *mut Simulation) {
    if !sim.is_null() {
        drop(Box::from_raw(sim));
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_tick(sim: *mut Simulation, delta_ms: u32) {
    if let Some(sim) = sim.as_mut() {
        sim.tick(delta_ms);
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_resize(sim: *mut Simulation, width: u32, height: u32) {
    if let Some(sim) = sim.as_mut() {
        sim.resize(width, height);
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
/// The returned pointer is valid until the next call to `rsmatrix_tick`, `rsmatrix_resize`, or `rsmatrix_destroy`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_get_grid(sim: *const Simulation) -> *const Cell {
    if let Some(sim) = sim.as_ref() {
        sim.grid().as_ptr()
    } else {
        std::ptr::null()
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_grid_width(sim: *const Simulation) -> u32 {
    if let Some(sim) = sim.as_ref() {
        sim.width()
    } else {
        0
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_grid_height(sim: *const Simulation) -> u32 {
    if let Some(sim) = sim.as_ref() {
        sim.height()
    } else {
        0
    }
}

/// # Safety
/// `sim` must be a valid pointer returned by `rsmatrix_create`.
#[no_mangle]
pub unsafe extern "C" fn rsmatrix_clear(sim: *mut Simulation) {
    if let Some(sim) = sim.as_mut() {
        sim.clear();
    }
}

#[no_mangle]
pub extern "C" fn rsmatrix_set_charset(mode: u32) {
    rsmatrix_core::charset::set_charset(mode as usize);
}
