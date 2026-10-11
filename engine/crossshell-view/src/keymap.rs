//! winit physical key codes → Linux evdev keycodes (the wire format).
//!
//! The wire carries physical key positions, so the remote's keyboard layout
//! decides the character a key types. evdev numbers come from
//! `linux/input-event-codes.h`.

use winit::keyboard::{KeyCode, NativeKeyCode, PhysicalKey};

/// evdev code for a winit physical key; `None` when the key has no sensible
/// remote equivalent (power keys, Fn, numpad memory keys, F25+, ...).
pub fn to_evdev(key: PhysicalKey) -> Option<u16> {
    match key {
        PhysicalKey::Code(c) => keycode_to_evdev(c),
        // X11 and Wayland report XKB keycodes, which are evdev + 8 on every
        // modern keymap. Covers keys winit has no KeyCode for.
        PhysicalKey::Unidentified(NativeKeyCode::Xkb(k)) => {
            let code = k.checked_sub(8)?;
            (1..=0x2ff).contains(&code).then_some(code as u16)
        }
        PhysicalKey::Unidentified(_) => None,
    }
}

pub fn keycode_to_evdev(code: KeyCode) -> Option<u16> {
    use KeyCode::*;
    Some(match code {
        Escape => 1,
        Digit1 => 2,
        Digit2 => 3,
        Digit3 => 4,
        Digit4 => 5,
        Digit5 => 6,
        Digit6 => 7,
        Digit7 => 8,
        Digit8 => 9,
        Digit9 => 10,
        Digit0 => 11,
        Minus => 12,
        Equal => 13,
        Backspace => 14,
        Tab => 15,
        KeyQ => 16,
        KeyW => 17,
        KeyE => 18,
        KeyR => 19,
        KeyT => 20,
        KeyY => 21,
        KeyU => 22,
        KeyI => 23,
        KeyO => 24,
        KeyP => 25,
        BracketLeft => 26,
        BracketRight => 27,
        Enter => 28,
        ControlLeft => 29,
        KeyA => 30,
        KeyS => 31,
        KeyD => 32,
        KeyF => 33,
        KeyG => 34,
        KeyH => 35,
        KeyJ => 36,
        KeyK => 37,
        KeyL => 38,
        Semicolon => 39,
        Quote => 40,
        Backquote => 41,
        ShiftLeft => 42,
        Backslash => 43,
        KeyZ => 44,
        KeyX => 45,
        KeyC => 46,
        KeyV => 47,
        KeyB => 48,
        KeyN => 49,
        KeyM => 50,
        Comma => 51,
        Period => 52,
        Slash => 53,
        ShiftRight => 54,
        NumpadMultiply | NumpadStar => 55,
        AltLeft => 56,
        Space => 57,
        CapsLock => 58,
        F1 => 59,
        F2 => 60,
        F3 => 61,
        F4 => 62,
        F5 => 63,
        F6 => 64,
        F7 => 65,
        F8 => 66,
        F9 => 67,
        F10 => 68,
        NumLock => 69,
        ScrollLock => 70,
        Numpad7 => 71,
        Numpad8 => 72,
        Numpad9 => 73,
        NumpadSubtract => 74,
        Numpad4 => 75,
        Numpad5 => 76,
        Numpad6 => 77,
        NumpadAdd => 78,
        Numpad1 => 79,
        Numpad2 => 80,
        Numpad3 => 81,
        Numpad0 => 82,
        NumpadDecimal => 83,
        Lang5 => 85,         // KEY_ZENKAKUHANKAKU
        IntlBackslash => 86, // KEY_102ND
        F11 => 87,
        F12 => 88,
        IntlRo => 89,
        Lang3 | Katakana => 90,
        Lang4 | Hiragana => 91,
        Convert => 92,    // KEY_HENKAN
        KanaMode => 93,   // KEY_KATAKANAHIRAGANA
        NonConvert => 94, // KEY_MUHENKAN
        NumpadEnter => 96,
        ControlRight => 97,
        NumpadDivide => 98,
        PrintScreen => 99, // KEY_SYSRQ
        AltRight => 100,
        Home => 102,
        ArrowUp => 103,
        PageUp => 104,
        ArrowLeft => 105,
        ArrowRight => 106,
        End => 107,
        ArrowDown => 108,
        PageDown => 109,
        Insert => 110,
        Delete => 111,
        AudioVolumeMute => 113,
        AudioVolumeDown => 114,
        AudioVolumeUp => 115,
        NumpadEqual => 117,
        Pause => 119,
        NumpadComma => 121,
        Lang1 => 122, // KEY_HANGEUL
        Lang2 => 123, // KEY_HANJA
        IntlYen => 124,
        SuperLeft | Meta => 125,
        SuperRight => 126,
        ContextMenu => 127, // KEY_COMPOSE, what menu keys send on Linux
        Again => 129,
        Props => 130,
        Undo => 131,
        Copy => 133,
        Open => 134,
        Paste => 135,
        Find => 136,
        Cut => 137,
        Help => 138,
        LaunchApp2 => 140, // KEY_CALC
        LaunchApp1 => 148, // KEY_PROG1
        LaunchMail => 155,
        BrowserFavorites => 156, // KEY_BOOKMARKS
        BrowserBack => 158,
        BrowserForward => 159,
        Eject => 161, // KEY_EJECTCD
        MediaTrackNext => 163,
        MediaPlayPause => 164,
        MediaTrackPrevious => 165,
        MediaStop => 166, // KEY_STOPCD
        BrowserStop => 128,
        BrowserHome => 172, // KEY_HOMEPAGE
        BrowserRefresh => 173,
        NumpadParenLeft => 179,
        NumpadParenRight => 180,
        F13 => 183,
        F14 => 184,
        F15 => 185,
        F16 => 186,
        F17 => 187,
        F18 => 188,
        F19 => 189,
        F20 => 190,
        F21 => 191,
        F22 => 192,
        F23 => 193,
        F24 => 194,
        BrowserSearch => 217,
        MediaSelect => 226, // KEY_MEDIA
        // No remote equivalent, or too dangerous to forward blindly
        // (Power, Sleep, WakeUp act on the machine, not the session).
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use KeyCode::*;

    /// Every `KeyCode` winit 0.30 has, so a test can check the table as a whole.
    const ALL: &[KeyCode] = &[
        Backquote,
        Backslash,
        BracketLeft,
        BracketRight,
        Comma,
        Digit0,
        Digit1,
        Digit2,
        Digit3,
        Digit4,
        Digit5,
        Digit6,
        Digit7,
        Digit8,
        Digit9,
        Equal,
        IntlBackslash,
        IntlRo,
        IntlYen,
        KeyA,
        KeyB,
        KeyC,
        KeyD,
        KeyE,
        KeyF,
        KeyG,
        KeyH,
        KeyI,
        KeyJ,
        KeyK,
        KeyL,
        KeyM,
        KeyN,
        KeyO,
        KeyP,
        KeyQ,
        KeyR,
        KeyS,
        KeyT,
        KeyU,
        KeyV,
        KeyW,
        KeyX,
        KeyY,
        KeyZ,
        Minus,
        Period,
        Quote,
        Semicolon,
        Slash,
        AltLeft,
        AltRight,
        Backspace,
        CapsLock,
        ContextMenu,
        ControlLeft,
        ControlRight,
        Enter,
        SuperLeft,
        SuperRight,
        ShiftLeft,
        ShiftRight,
        Space,
        Tab,
        Convert,
        KanaMode,
        Lang1,
        Lang2,
        Lang3,
        Lang4,
        Lang5,
        NonConvert,
        Delete,
        End,
        Help,
        Home,
        Insert,
        PageDown,
        PageUp,
        ArrowDown,
        ArrowLeft,
        ArrowRight,
        ArrowUp,
        NumLock,
        Numpad0,
        Numpad1,
        Numpad2,
        Numpad3,
        Numpad4,
        Numpad5,
        Numpad6,
        Numpad7,
        Numpad8,
        Numpad9,
        NumpadAdd,
        NumpadBackspace,
        NumpadClear,
        NumpadClearEntry,
        NumpadComma,
        NumpadDecimal,
        NumpadDivide,
        NumpadEnter,
        NumpadEqual,
        NumpadHash,
        NumpadMemoryAdd,
        NumpadMemoryClear,
        NumpadMemoryRecall,
        NumpadMemoryStore,
        NumpadMemorySubtract,
        NumpadMultiply,
        NumpadParenLeft,
        NumpadParenRight,
        NumpadStar,
        NumpadSubtract,
        Escape,
        Fn,
        FnLock,
        PrintScreen,
        ScrollLock,
        Pause,
        BrowserBack,
        BrowserFavorites,
        BrowserForward,
        BrowserHome,
        BrowserRefresh,
        BrowserSearch,
        BrowserStop,
        Eject,
        LaunchApp1,
        LaunchApp2,
        LaunchMail,
        MediaPlayPause,
        MediaSelect,
        MediaStop,
        MediaTrackNext,
        MediaTrackPrevious,
        Power,
        Sleep,
        AudioVolumeDown,
        AudioVolumeMute,
        AudioVolumeUp,
        WakeUp,
        Meta,
        Hyper,
        Turbo,
        Abort,
        Resume,
        Suspend,
        Again,
        Copy,
        Cut,
        Find,
        Open,
        Paste,
        Props,
        Select,
        Undo,
        Hiragana,
        Katakana,
        F1,
        F2,
        F3,
        F4,
        F5,
        F6,
        F7,
        F8,
        F9,
        F10,
        F11,
        F12,
        F13,
        F14,
        F15,
        F16,
        F17,
        F18,
        F19,
        F20,
        F21,
        F22,
        F23,
        F24,
        F25,
        F26,
        F27,
        F28,
        F29,
        F30,
        F31,
        F32,
        F33,
        F34,
        F35,
    ];

    #[test]
    fn letters_digits_and_punctuation() {
        assert_eq!(keycode_to_evdev(KeyA), Some(30));
        assert_eq!(keycode_to_evdev(KeyQ), Some(16));
        assert_eq!(keycode_to_evdev(KeyZ), Some(44));
        assert_eq!(keycode_to_evdev(KeyM), Some(50));
        assert_eq!(keycode_to_evdev(Digit1), Some(2));
        assert_eq!(keycode_to_evdev(Digit0), Some(11));
        assert_eq!(keycode_to_evdev(Minus), Some(12));
        assert_eq!(keycode_to_evdev(Equal), Some(13));
        assert_eq!(keycode_to_evdev(BracketLeft), Some(26));
        assert_eq!(keycode_to_evdev(Backquote), Some(41));
        assert_eq!(keycode_to_evdev(Backslash), Some(43));
        assert_eq!(keycode_to_evdev(Slash), Some(53));
        assert_eq!(keycode_to_evdev(Space), Some(57));
        assert_eq!(keycode_to_evdev(Enter), Some(28));
    }

    #[test]
    fn modifiers_and_navigation() {
        assert_eq!(keycode_to_evdev(ControlLeft), Some(29));
        assert_eq!(keycode_to_evdev(ControlRight), Some(97));
        assert_eq!(keycode_to_evdev(ShiftLeft), Some(42));
        assert_eq!(keycode_to_evdev(ShiftRight), Some(54));
        assert_eq!(keycode_to_evdev(AltLeft), Some(56));
        assert_eq!(keycode_to_evdev(AltRight), Some(100));
        assert_eq!(keycode_to_evdev(SuperLeft), Some(125));
        assert_eq!(keycode_to_evdev(SuperRight), Some(126));
        assert_eq!(keycode_to_evdev(Meta), Some(125));
        assert_eq!(keycode_to_evdev(ArrowUp), Some(103));
        assert_eq!(keycode_to_evdev(ArrowLeft), Some(105));
        assert_eq!(keycode_to_evdev(ArrowRight), Some(106));
        assert_eq!(keycode_to_evdev(ArrowDown), Some(108));
        assert_eq!(keycode_to_evdev(Home), Some(102));
        assert_eq!(keycode_to_evdev(End), Some(107));
        assert_eq!(keycode_to_evdev(PageUp), Some(104));
        assert_eq!(keycode_to_evdev(PageDown), Some(109));
        assert_eq!(keycode_to_evdev(Insert), Some(110));
        assert_eq!(keycode_to_evdev(Delete), Some(111));
        assert_eq!(keycode_to_evdev(PrintScreen), Some(99));
        assert_eq!(keycode_to_evdev(ContextMenu), Some(127));
    }

    #[test]
    fn function_keys() {
        assert_eq!(keycode_to_evdev(F1), Some(59));
        assert_eq!(keycode_to_evdev(F10), Some(68));
        assert_eq!(keycode_to_evdev(F11), Some(87));
        assert_eq!(keycode_to_evdev(F12), Some(88));
        assert_eq!(keycode_to_evdev(F13), Some(183));
        assert_eq!(keycode_to_evdev(F24), Some(194));
        assert_eq!(keycode_to_evdev(F25), None);
        // F13..F24 are contiguous.
        for (i, k) in [F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24].iter().enumerate() {
            assert_eq!(keycode_to_evdev(*k), Some(183 + i as u16));
        }
    }

    #[test]
    fn keypad() {
        assert_eq!(keycode_to_evdev(Numpad0), Some(82));
        assert_eq!(keycode_to_evdev(Numpad1), Some(79));
        assert_eq!(keycode_to_evdev(Numpad5), Some(76));
        assert_eq!(keycode_to_evdev(Numpad9), Some(73));
        assert_eq!(keycode_to_evdev(NumpadAdd), Some(78));
        assert_eq!(keycode_to_evdev(NumpadSubtract), Some(74));
        assert_eq!(keycode_to_evdev(NumpadMultiply), Some(55));
        assert_eq!(keycode_to_evdev(NumpadDivide), Some(98));
        assert_eq!(keycode_to_evdev(NumpadDecimal), Some(83));
        assert_eq!(keycode_to_evdev(NumpadEnter), Some(96));
        assert_eq!(keycode_to_evdev(NumpadEqual), Some(117));
        assert_eq!(keycode_to_evdev(NumpadComma), Some(121));
        assert_eq!(keycode_to_evdev(NumLock), Some(69));
    }

    #[test]
    fn international_and_lang_keys() {
        assert_eq!(keycode_to_evdev(IntlBackslash), Some(86));
        assert_eq!(keycode_to_evdev(IntlRo), Some(89));
        assert_eq!(keycode_to_evdev(IntlYen), Some(124));
        assert_eq!(keycode_to_evdev(Lang1), Some(122));
        assert_eq!(keycode_to_evdev(Lang2), Some(123));
        assert_eq!(keycode_to_evdev(Lang3), Some(90));
        assert_eq!(keycode_to_evdev(Lang4), Some(91));
        assert_eq!(keycode_to_evdev(Lang5), Some(85));
        assert_eq!(keycode_to_evdev(Convert), Some(92));
        assert_eq!(keycode_to_evdev(NonConvert), Some(94));
        assert_eq!(keycode_to_evdev(KanaMode), Some(93));
    }

    #[test]
    fn media_keys() {
        assert_eq!(keycode_to_evdev(AudioVolumeMute), Some(113));
        assert_eq!(keycode_to_evdev(AudioVolumeDown), Some(114));
        assert_eq!(keycode_to_evdev(AudioVolumeUp), Some(115));
        assert_eq!(keycode_to_evdev(MediaTrackNext), Some(163));
        assert_eq!(keycode_to_evdev(MediaPlayPause), Some(164));
        assert_eq!(keycode_to_evdev(MediaTrackPrevious), Some(165));
        assert_eq!(keycode_to_evdev(MediaStop), Some(166));
    }

    #[test]
    fn machine_level_keys_are_not_forwarded() {
        for k in [Power, Sleep, WakeUp, Fn, FnLock, Hyper, Turbo] {
            assert_eq!(keycode_to_evdev(k), None, "{k:?}");
        }
    }

    #[test]
    fn only_deliberate_aliases_share_a_code() {
        let mut seen: HashMap<u16, KeyCode> = HashMap::new();
        for &k in ALL {
            if let Some(code) = keycode_to_evdev(k) {
                assert!(code != 0 && code < 0x100, "{k:?} -> {code}");
                if let Some(prev) = seen.insert(code, k) {
                    let alias = matches!(
                        (prev, k),
                        (NumpadMultiply, NumpadStar) | (SuperLeft, Meta) | (Lang3, Katakana) | (Lang4, Hiragana)
                    );
                    assert!(alias, "{prev:?} and {k:?} both map to {code}");
                }
            }
        }
        // The common keys must all be present.
        assert!(seen.len() > 140, "only {} codes mapped", seen.len());
    }

    #[test]
    fn host_can_synthesize_every_main_block_key() {
        // The Windows host maps these evdev codes to scancodes; a mismatch
        // between the two tables would silently drop keys.
        for &k in ALL {
            let Some(code) = keycode_to_evdev(k) else { continue };
            let main_block = matches!(
                k,
                KeyA | KeyB
                    | KeyC
                    | KeyD
                    | KeyE
                    | KeyF
                    | KeyG
                    | KeyH
                    | KeyI
                    | KeyJ
                    | KeyK
                    | KeyL
                    | KeyM
                    | KeyN
                    | KeyO
                    | KeyP
                    | KeyQ
                    | KeyR
                    | KeyS
                    | KeyT
                    | KeyU
                    | KeyV
                    | KeyW
                    | KeyX
                    | KeyY
                    | KeyZ
                    | Digit0
                    | Digit1
                    | Digit2
                    | Digit3
                    | Digit4
                    | Digit5
                    | Digit6
                    | Digit7
                    | Digit8
                    | Digit9
                    | Space
                    | Enter
                    | Tab
                    | Backspace
                    | Escape
                    | ShiftLeft
                    | ShiftRight
                    | ControlLeft
                    | ControlRight
                    | AltLeft
                    | AltRight
                    | SuperLeft
                    | SuperRight
                    | ArrowUp
                    | ArrowDown
                    | ArrowLeft
                    | ArrowRight
                    | Home
                    | End
                    | PageUp
                    | PageDown
                    | Insert
                    | Delete
                    | F1
                    | F2
                    | F3
                    | F4
                    | F5
                    | F6
                    | F7
                    | F8
                    | F9
                    | F10
                    | F11
                    | F12
                    | F13
                    | F24
                    | Numpad0
                    | NumpadEnter
                    | IntlBackslash
            );
            if main_block {
                assert!(
                    crossshell_proto::keymap::evdev_to_windows(code).is_some(),
                    "{k:?} (evdev {code}) has no Windows mapping"
                );
            }
        }
    }

    #[test]
    fn xkb_fallback_is_evdev_plus_eight() {
        assert_eq!(to_evdev(PhysicalKey::Unidentified(NativeKeyCode::Xkb(38))), Some(30));
        assert_eq!(to_evdev(PhysicalKey::Unidentified(NativeKeyCode::Xkb(8))), None);
        assert_eq!(to_evdev(PhysicalKey::Unidentified(NativeKeyCode::Xkb(3))), None);
        assert_eq!(to_evdev(PhysicalKey::Unidentified(NativeKeyCode::Windows(0x1e))), None);
        assert_eq!(to_evdev(PhysicalKey::Code(KeyA)), Some(30));
    }
}
