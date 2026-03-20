use std::sync::atomic::{AtomicUsize, Ordering};

/// Half-width katakana: U+FF61 through U+FF9F (63 characters)
const HALF_WIDTH_KANA: &[char] = &[
    '\u{FF61}', '\u{FF62}', '\u{FF63}', '\u{FF64}', '\u{FF65}', '\u{FF66}', '\u{FF67}',
    '\u{FF68}', '\u{FF69}', '\u{FF6A}', '\u{FF6B}', '\u{FF6C}', '\u{FF6D}', '\u{FF6E}',
    '\u{FF6F}', '\u{FF70}', '\u{FF71}', '\u{FF72}', '\u{FF73}', '\u{FF74}', '\u{FF75}',
    '\u{FF76}', '\u{FF77}', '\u{FF78}', '\u{FF79}', '\u{FF7A}', '\u{FF7B}', '\u{FF7C}',
    '\u{FF7D}', '\u{FF7E}', '\u{FF7F}', '\u{FF80}', '\u{FF81}', '\u{FF82}', '\u{FF83}',
    '\u{FF84}', '\u{FF85}', '\u{FF86}', '\u{FF87}', '\u{FF88}', '\u{FF89}', '\u{FF8A}',
    '\u{FF8B}', '\u{FF8C}', '\u{FF8D}', '\u{FF8E}', '\u{FF8F}', '\u{FF90}', '\u{FF91}',
    '\u{FF92}', '\u{FF93}', '\u{FF94}', '\u{FF95}', '\u{FF96}', '\u{FF97}', '\u{FF98}',
    '\u{FF99}', '\u{FF9A}', '\u{FF9B}', '\u{FF9C}', '\u{FF9D}', '\u{FF9E}', '\u{FF9F}',
];

/// ASCII alphanumeric: A-Z, a-z, 0-9 (62 characters)
const ALPHA_NUMERICS: &[char] = &[
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
];

/// Character set indices for atomic switching.
pub const CHARSET_COMBINED: usize = 0;
pub const CHARSET_ASCII: usize = 1;
pub const CHARSET_KANA: usize = 2;

/// Global atomic charset selector.
static CURRENT_CHARSET: AtomicUsize = AtomicUsize::new(CHARSET_COMBINED);

/// Combined charset built at first access.
fn combined_chars() -> &'static [char] {
    use std::sync::OnceLock;
    static COMBINED: OnceLock<Vec<char>> = OnceLock::new();
    COMBINED.get_or_init(|| {
        let mut v = Vec::with_capacity(HALF_WIDTH_KANA.len() + ALPHA_NUMERICS.len());
        v.extend_from_slice(HALF_WIDTH_KANA);
        v.extend_from_slice(ALPHA_NUMERICS);
        v
    })
}

pub fn set_charset(index: usize) {
    CURRENT_CHARSET.store(index, Ordering::Relaxed);
}

pub fn get_charset() -> &'static [char] {
    match CURRENT_CHARSET.load(Ordering::Relaxed) {
        CHARSET_ASCII => ALPHA_NUMERICS,
        CHARSET_KANA => HALF_WIDTH_KANA,
        _ => combined_chars(),
    }
}

pub fn random_char(rng: &mut impl rand::RngExt) -> char {
    let chars = get_charset();
    chars[rng.random_range(0..chars.len())]
}
