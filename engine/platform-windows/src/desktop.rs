//! Which desktop is receiving input: the user's `Default` desktop, or a
//! secure one (Winlogon: lock screen, sign-in, Ctrl+Alt+Del, UAC prompts)
//! that a process in the user's session can neither capture nor drive.

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, UOI_NAME,
};

use crate::displays::wide_to_string;

pub(crate) const SECURE_DESKTOP: &str = "The remote PC is showing a secure screen (lock screen, sign-in, \
     Ctrl+Alt+Del or an administrator prompt) that can't be shared. The picture comes back when it closes.";

/// Name of the input desktop; `None` when we may not open it, which for a
/// user-session process means Winlogon's secure desktop is up.
pub(crate) fn input_desktop_name() -> Option<String> {
    unsafe {
        let desk = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS).ok()?;
        let mut buf = [0u16; 64];
        let mut needed = 0u32;
        let ok = GetUserObjectInformationW(
            HANDLE(desk.0),
            UOI_NAME,
            Some(buf.as_mut_ptr().cast()),
            size_of_val(&buf) as u32,
            Some(&mut needed),
        );
        let _ = CloseDesktop(desk);
        ok.ok()?;
        Some(wide_to_string(&buf))
    }
}

/// True when input currently goes to a desktop other than `Default`.
pub(crate) fn secure_desktop_active() -> bool {
    !input_desktop_name().is_some_and(|n| n.eq_ignore_ascii_case("Default"))
}
