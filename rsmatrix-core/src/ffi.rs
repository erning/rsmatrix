use crate::simulation::{Cell, Simulation};

#[no_mangle]
pub extern "C" fn rsmatrix_create(width: u32, height: u32) -> *mut Simulation {
    let sim = Box::new(Simulation::new(width, height));
    Box::into_raw(sim)
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_destroy(sim: *mut Simulation) {
    if !sim.is_null() {
        drop(Box::from_raw(sim));
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_tick(sim: *mut Simulation, delta_ms: u32) {
    if let Some(sim) = sim.as_mut() {
        sim.tick(delta_ms);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_resize(sim: *mut Simulation, width: u32, height: u32) {
    if let Some(sim) = sim.as_mut() {
        sim.resize(width, height);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_get_grid(sim: *const Simulation) -> *const Cell {
    if let Some(sim) = sim.as_ref() {
        sim.grid().as_ptr()
    } else {
        std::ptr::null()
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_grid_width(sim: *const Simulation) -> u32 {
    if let Some(sim) = sim.as_ref() {
        sim.width()
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn rsmatrix_grid_height(sim: *const Simulation) -> u32 {
    if let Some(sim) = sim.as_ref() {
        sim.height()
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn rsmatrix_set_charset(mode: u32) {
    crate::charset::set_charset(mode as usize);
}
