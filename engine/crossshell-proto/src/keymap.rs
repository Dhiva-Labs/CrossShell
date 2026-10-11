//! Keyboard mapping.
//!
//! The wire carries Linux evdev keycodes (`linux/input-event-codes.h`):
//! physical key positions, independent of layout — the host's own keyboard
//! layout decides which character a key produces, exactly like a real
//! keyboard plugged into the host.
//!
//! The viewer maps its windowing toolkit's physical key codes to evdev; the
//! Windows host maps evdev to PS/2 set-1 scancodes for `SendInput`.

/// evdev keycodes used by the mapping tables.
#[allow(dead_code)]
pub mod evdev {
    pub const KEY_ESC: u16 = 1;
    pub const KEY_1: u16 = 2;
    pub const KEY_0: u16 = 11;
    pub const KEY_MINUS: u16 = 12;
    pub const KEY_EQUAL: u16 = 13;
    pub const KEY_BACKSPACE: u16 = 14;
    pub const KEY_TAB: u16 = 15;
    pub const KEY_Q: u16 = 16;
    pub const KEY_W: u16 = 17;
    pub const KEY_E: u16 = 18;
    pub const KEY_R: u16 = 19;
    pub const KEY_T: u16 = 20;
    pub const KEY_Y: u16 = 21;
    pub const KEY_U: u16 = 22;
    pub const KEY_I: u16 = 23;
    pub const KEY_O: u16 = 24;
    pub const KEY_P: u16 = 25;
    pub const KEY_LEFTBRACE: u16 = 26;
    pub const KEY_RIGHTBRACE: u16 = 27;
    pub const KEY_ENTER: u16 = 28;
    pub const KEY_LEFTCTRL: u16 = 29;
    pub const KEY_A: u16 = 30;
    pub const KEY_S: u16 = 31;
    pub const KEY_D: u16 = 32;
    pub const KEY_F: u16 = 33;
    pub const KEY_G: u16 = 34;
    pub const KEY_H: u16 = 35;
    pub const KEY_J: u16 = 36;
    pub const KEY_K: u16 = 37;
    pub const KEY_L: u16 = 38;
    pub const KEY_SEMICOLON: u16 = 39;
    pub const KEY_APOSTROPHE: u16 = 40;
    pub const KEY_GRAVE: u16 = 41;
    pub const KEY_LEFTSHIFT: u16 = 42;
    pub const KEY_BACKSLASH: u16 = 43;
    pub const KEY_Z: u16 = 44;
    pub const KEY_X: u16 = 45;
    pub const KEY_C: u16 = 46;
    pub const KEY_V: u16 = 47;
    pub const KEY_B: u16 = 48;
    pub const KEY_N: u16 = 49;
    pub const KEY_M: u16 = 50;
    pub const KEY_COMMA: u16 = 51;
    pub const KEY_DOT: u16 = 52;
    pub const KEY_SLASH: u16 = 53;
    pub const KEY_RIGHTSHIFT: u16 = 54;
    pub const KEY_KPASTERISK: u16 = 55;
    pub const KEY_LEFTALT: u16 = 56;
    pub const KEY_SPACE: u16 = 57;
    pub const KEY_CAPSLOCK: u16 = 58;
    pub const KEY_F1: u16 = 59;
    pub const KEY_F10: u16 = 68;
    pub const KEY_NUMLOCK: u16 = 69;
    pub const KEY_SCROLLLOCK: u16 = 70;
    pub const KEY_KP7: u16 = 71;
    pub const KEY_KP8: u16 = 72;
    pub const KEY_KP9: u16 = 73;
    pub const KEY_KPMINUS: u16 = 74;
    pub const KEY_KP4: u16 = 75;
    pub const KEY_KP5: u16 = 76;
    pub const KEY_KP6: u16 = 77;
    pub const KEY_KPPLUS: u16 = 78;
    pub const KEY_KP1: u16 = 79;
    pub const KEY_KP2: u16 = 80;
    pub const KEY_KP3: u16 = 81;
    pub const KEY_KP0: u16 = 82;
    pub const KEY_KPDOT: u16 = 83;
    pub const KEY_ZENKAKUHANKAKU: u16 = 85;
    pub const KEY_102ND: u16 = 86;
    pub const KEY_F11: u16 = 87;
    pub const KEY_F12: u16 = 88;
    pub const KEY_RO: u16 = 89;
    pub const KEY_KATAKANA: u16 = 90;
    pub const KEY_HIRAGANA: u16 = 91;
    pub const KEY_HENKAN: u16 = 92;
    pub const KEY_KATAKANAHIRAGANA: u16 = 93;
    pub const KEY_MUHENKAN: u16 = 94;
    pub const KEY_KPENTER: u16 = 96;
    pub const KEY_RIGHTCTRL: u16 = 97;
    pub const KEY_KPSLASH: u16 = 98;
    pub const KEY_SYSRQ: u16 = 99;
    pub const KEY_RIGHTALT: u16 = 100;
    pub const KEY_HOME: u16 = 102;
    pub const KEY_UP: u16 = 103;
    pub const KEY_PAGEUP: u16 = 104;
    pub const KEY_LEFT: u16 = 105;
    pub const KEY_RIGHT: u16 = 106;
    pub const KEY_END: u16 = 107;
    pub const KEY_DOWN: u16 = 108;
    pub const KEY_PAGEDOWN: u16 = 109;
    pub const KEY_INSERT: u16 = 110;
    pub const KEY_DELETE: u16 = 111;
    pub const KEY_MUTE: u16 = 113;
    pub const KEY_VOLUMEDOWN: u16 = 114;
    pub const KEY_VOLUMEUP: u16 = 115;
    pub const KEY_KPEQUAL: u16 = 117;
    pub const KEY_PAUSE: u16 = 119;
    pub const KEY_KPCOMMA: u16 = 121;
    pub const KEY_HANGEUL: u16 = 122;
    pub const KEY_HANJA: u16 = 123;
    pub const KEY_YEN: u16 = 124;
    pub const KEY_LEFTMETA: u16 = 125;
    pub const KEY_RIGHTMETA: u16 = 126;
    pub const KEY_COMPOSE: u16 = 127;
    pub const KEY_NEXTSONG: u16 = 163;
    pub const KEY_PLAYPAUSE: u16 = 164;
    pub const KEY_PREVIOUSSONG: u16 = 165;
    pub const KEY_STOPCD: u16 = 166;
    pub const KEY_F13: u16 = 183;
    pub const KEY_F24: u16 = 194;

    pub const BTN_LEFT: u16 = 0x110;
    pub const BTN_RIGHT: u16 = 0x111;
    pub const BTN_MIDDLE: u16 = 0x112;
    pub const BTN_SIDE: u16 = 0x113;
    pub const BTN_EXTRA: u16 = 0x114;
}

/// How the Windows host should synthesize a key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinKey {
    /// `SendInput` with `KEYEVENTF_SCANCODE` (+ `KEYEVENTF_EXTENDEDKEY` when `extended`).
    Scan { code: u16, extended: bool },
    /// Keys whose scancode path is unreliable in `SendInput` (Pause's E1
    /// sequence, NumLock's E0 quirk): send this virtual-key code instead.
    Vk(u16),
}

/// Map an evdev keycode to a Windows key. `None` = no Windows equivalent.
pub fn evdev_to_windows(code: u16) -> Option<WinKey> {
    use evdev::*;
    let scan = |code: u16| Some(WinKey::Scan { code, extended: false });
    let ext = |code: u16| Some(WinKey::Scan { code, extended: true });
    match code {
        // The main block, F1–F10 and the keypad: evdev was defined to equal
        // set-1 scancodes for these. NumLock is special-cased below.
        KEY_NUMLOCK => Some(WinKey::Vk(0x90)),
        1..=83 => scan(code),
        KEY_102ND => scan(0x56),
        KEY_F11 => scan(0x57),
        KEY_F12 => scan(0x58),
        KEY_KPEQUAL => scan(0x59),
        KEY_RO => scan(0x73),
        KEY_KATAKANAHIRAGANA => scan(0x70),
        KEY_HENKAN => scan(0x79),
        KEY_MUHENKAN => scan(0x7b),
        KEY_YEN => scan(0x7d),
        KEY_KPCOMMA => scan(0x7e),
        KEY_HANGEUL => scan(0x72),
        KEY_HANJA => scan(0x71),
        KEY_F13..=KEY_F24 => {
            const F13_TO_F24: [u16; 12] =
                [0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x76];
            scan(F13_TO_F24[(code - KEY_F13) as usize])
        }
        KEY_KPENTER => ext(0x1c),
        KEY_RIGHTCTRL => ext(0x1d),
        KEY_KPSLASH => ext(0x35),
        KEY_SYSRQ => ext(0x37),
        KEY_RIGHTALT => ext(0x38),
        KEY_HOME => ext(0x47),
        KEY_UP => ext(0x48),
        KEY_PAGEUP => ext(0x49),
        KEY_LEFT => ext(0x4b),
        KEY_RIGHT => ext(0x4d),
        KEY_END => ext(0x4f),
        KEY_DOWN => ext(0x50),
        KEY_PAGEDOWN => ext(0x51),
        KEY_INSERT => ext(0x52),
        KEY_DELETE => ext(0x53),
        KEY_LEFTMETA => ext(0x5b),
        KEY_RIGHTMETA => ext(0x5c),
        KEY_COMPOSE => ext(0x5d),
        KEY_MUTE => ext(0x20),
        KEY_VOLUMEDOWN => ext(0x2e),
        KEY_VOLUMEUP => ext(0x30),
        KEY_NEXTSONG => ext(0x19),
        KEY_PREVIOUSSONG => ext(0x10),
        KEY_PLAYPAUSE => ext(0x22),
        KEY_STOPCD => ext(0x24),
        KEY_PAUSE => Some(WinKey::Vk(0x13)),
        _ => None,
    }
}

/// X11 keycodes are evdev + 8 (the XKB "evdev" rules every modern X server uses).
pub fn evdev_to_x11(code: u16) -> Option<u8> {
    u8::try_from(code as u32 + 8).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use evdev::*;

    #[test]
    fn main_block_is_identity() {
        assert_eq!(evdev_to_windows(KEY_A), Some(WinKey::Scan { code: 0x1e, extended: false }));
        assert_eq!(evdev_to_windows(KEY_ESC), Some(WinKey::Scan { code: 0x01, extended: false }));
        assert_eq!(evdev_to_windows(KEY_KPDOT), Some(WinKey::Scan { code: 0x53, extended: false }));
    }

    #[test]
    fn extended_keys_carry_the_flag() {
        for k in [KEY_UP, KEY_DELETE, KEY_RIGHTCTRL, KEY_RIGHTALT, KEY_LEFTMETA, KEY_KPENTER] {
            assert!(matches!(evdev_to_windows(k), Some(WinKey::Scan { extended: true, .. })), "{k}");
        }
        // Same scancode, different key: keypad 8 vs. arrow up.
        assert_eq!(evdev_to_windows(KEY_KP8), Some(WinKey::Scan { code: 0x48, extended: false }));
        assert_eq!(evdev_to_windows(KEY_UP), Some(WinKey::Scan { code: 0x48, extended: true }));
    }

    #[test]
    fn quirky_keys_use_virtual_keys() {
        assert_eq!(evdev_to_windows(KEY_PAUSE), Some(WinKey::Vk(0x13)));
        assert_eq!(evdev_to_windows(KEY_NUMLOCK), Some(WinKey::Vk(0x90)));
    }

    #[test]
    fn function_keys() {
        assert_eq!(evdev_to_windows(KEY_F1), Some(WinKey::Scan { code: 0x3b, extended: false }));
        assert_eq!(evdev_to_windows(KEY_F12), Some(WinKey::Scan { code: 0x58, extended: false }));
        assert_eq!(evdev_to_windows(KEY_F24), Some(WinKey::Scan { code: 0x76, extended: false }));
    }

    #[test]
    fn unknown_codes_map_to_none() {
        assert_eq!(evdev_to_windows(0), None);
        assert_eq!(evdev_to_windows(BTN_LEFT), None);
        assert_eq!(evdev_to_x11(KEY_A), Some(38));
        assert_eq!(evdev_to_x11(300), None);
    }
}
