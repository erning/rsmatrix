use std::sync::atomic::{AtomicUsize, Ordering};

/// Half-width katakana: U+FF61 through U+FF9F (63 characters)
const HALF_WIDTH_KANA: &[char] = &[
    '｡', '｢', '｣', '､', '･', 'ｦ', 'ｧ', 'ｨ', 'ｩ', 'ｪ', 'ｫ', 'ｬ', 'ｭ', 'ｮ', 'ｯ',
    'ｰ', 'ｱ', 'ｲ', 'ｳ', 'ｴ', 'ｵ', 'ｶ', 'ｷ', 'ｸ', 'ｹ', 'ｺ', 'ｻ', 'ｼ', 'ｽ', 'ｾ', 'ｿ',
    'ﾀ', 'ﾁ', 'ﾂ', 'ﾃ', 'ﾄ', 'ﾅ', 'ﾆ', 'ﾇ', 'ﾈ', 'ﾉ', 'ﾊ', 'ﾋ', 'ﾌ', 'ﾍ', 'ﾎ', 'ﾏ',
    'ﾐ', 'ﾑ', 'ﾒ', 'ﾓ', 'ﾔ', 'ﾕ', 'ﾖ', 'ﾗ', 'ﾘ', 'ﾙ', 'ﾚ', 'ﾛ', 'ﾜ', 'ﾝ', 'ﾞ', 'ﾟ',
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

pub fn random_char(rng: &mut impl rand::Rng) -> char {
    let chars = get_charset();
    chars[rng.gen_range(0..chars.len())]
}
