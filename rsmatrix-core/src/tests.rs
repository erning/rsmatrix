use crate::charset;
use crate::simulation::Simulation;

#[test]
fn new_creates_correct_grid_size() {
    let sim = Simulation::new(80, 24);
    assert_eq!(sim.grid().len(), 80 * 24);
    assert_eq!(sim.width(), 80);
    assert_eq!(sim.height(), 24);
}

#[test]
fn tick_does_not_panic() {
    let mut sim = Simulation::new(80, 24);
    sim.tick(0);
    sim.tick(1);
    sim.tick(16);
    sim.tick(100);
    sim.tick(1000);
    sim.tick(u32::MAX);
}

#[test]
fn resize_updates_grid() {
    let mut sim = Simulation::new(80, 24);
    sim.resize(40, 12);
    assert_eq!(sim.grid().len(), 40 * 12);
    assert_eq!(sim.width(), 40);
    assert_eq!(sim.height(), 12);
}

#[test]
fn clear_blanks_all_cells() {
    let mut sim = Simulation::new(80, 24);
    sim.tick(500);
    sim.clear();
    for cell in sim.grid() {
        assert_eq!(cell.codepoint, ' ' as u32);
        assert_eq!(cell.r, 0);
        assert_eq!(cell.g, 0);
        assert_eq!(cell.b, 0);
    }
}

#[test]
#[should_panic(expected = "grid too large")]
fn checked_grid_size_too_large() {
    // 5000 * 4000 = 20_000_000 > MAX_GRID_CELLS (16_000_000)
    Simulation::new(5_000, 4_000);
}

#[test]
fn get_charset_returns_valid_slices() {
    charset::set_charset(charset::CHARSET_ASCII);
    let ascii = charset::get_charset();
    assert!(!ascii.is_empty());
    assert!(ascii.iter().all(|c| c.is_ascii_alphanumeric()));

    charset::set_charset(charset::CHARSET_KANA);
    let kana = charset::get_charset();
    assert!(!kana.is_empty());

    charset::set_charset(charset::CHARSET_COMBINED);
    let combined = charset::get_charset();
    assert!(combined.len() > ascii.len());
    assert!(combined.len() > kana.len());
}

#[test]
fn zero_dimension_creates_empty_grid() {
    let sim = Simulation::new(0, 0);
    assert_eq!(sim.grid().len(), 0);
}
