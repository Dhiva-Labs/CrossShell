//! Bitmap text. The glyph table is the public-domain X11 "8x13" font, laid
//! out in 8x16 cells (one blank row above, two below) and scaled by an
//! integer factor for HiDPI.

use crate::font_data::{GLYPHS, GLYPH_H, RANGES};

pub const CELL_W: i32 = 8;
pub const CELL_H: i32 = 16;

/// Glyph for `c`; characters outside Latin-1 draw as `?`.
pub fn glyph(c: char) -> &'static [u8; GLYPH_H] {
    let u = c as u32;
    let mut base = 0usize;
    for (lo, hi) in RANGES {
        if (lo..=hi).contains(&u) {
            return &GLYPHS[base + (u - lo) as usize];
        }
        base += (hi - lo + 1) as usize;
    }
    glyph('?')
}

/// Replace typographic characters the font lacks with ASCII look-alikes.
pub fn sanitize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\u{2026}' => out.push_str("..."),
            '\u{2013}' | '\u{2014}' | '\u{2212}' => out.push('-'),
            '\u{2018}' | '\u{2019}' => out.push('\''),
            '\u{201c}' | '\u{201d}' => out.push('"'),
            '\u{2022}' => out.push('*'),
            '\n' | '\r' | '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// Shorten `text` to at most `max_chars` characters, ending in "..." if cut.
pub fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_owned();
    }
    if max_chars <= 3 {
        return text.chars().take(max_chars).collect();
    }
    let mut s: String = text.chars().take(max_chars - 3).collect();
    s.push_str("...");
    s
}

/// Greedy word wrap to lines of at most `max_chars` characters; words longer
/// than a line are split.
pub fn wrap(text: &str, max_chars: usize) -> Vec<String> {
    let max_chars = max_chars.max(1);
    let mut lines = Vec::new();
    let mut cur = String::new();
    for word in text.split_whitespace() {
        let mut word: String = word.to_owned();
        while word.chars().count() > max_chars {
            if !cur.is_empty() {
                lines.push(std::mem::take(&mut cur));
            }
            let head: String = word.chars().take(max_chars).collect();
            word = word.chars().skip(max_chars).collect();
            lines.push(head);
        }
        let need = if cur.is_empty() { 0 } else { 1 } + word.chars().count();
        if cur.chars().count() + need > max_chars {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(&word);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glyph_lookup() {
        // 'A' has ink, space has none, an unmapped char falls back to '?'.
        assert!(glyph('A').iter().any(|b| *b != 0));
        assert!(glyph(' ').iter().all(|b| *b == 0));
        assert_eq!(glyph('\u{4e2d}'), glyph('?'));
        // Latin-1 range is reachable ('é' = U+00E9).
        assert!(glyph('\u{e9}').iter().any(|b| *b != 0));
        assert_ne!(glyph('\u{e9}'), glyph('?'));
        // Neighbouring ASCII glyphs differ.
        assert_ne!(glyph('l'), glyph('I'));
        assert_eq!(GLYPHS.len(), 95 + 96);
    }

    #[test]
    fn sanitize_maps_typography() {
        assert_eq!(sanitize("Connecting\u{2026}"), "Connecting...");
        assert_eq!(sanitize("a\u{2014}b\nc"), "a-b c");
        assert_eq!(sanitize("it\u{2019}s"), "it's");
    }

    #[test]
    fn truncation() {
        assert_eq!(truncate("hello", 10), "hello");
        assert_eq!(truncate("hello world", 8), "hello...");
        assert_eq!(truncate("hello", 2), "he");
    }

    #[test]
    fn wrapping() {
        assert_eq!(wrap("the quick brown fox", 9), ["the quick", "brown fox"]);
        assert_eq!(wrap("short", 40), ["short"]);
        assert_eq!(wrap("abcdefghij", 4), ["abcd", "efgh", "ij"]);
        assert!(wrap("", 10).is_empty());
        for l in wrap("Disconnected: the remote side stopped responding for 15 s", 20) {
            assert!(l.chars().count() <= 20, "{l}");
        }
    }
}
