//! The Ctrl+Alt+M overlay menu: items, layout, hit testing and keyboard
//! navigation. Drawing lives in `render.rs`.

use crossshell_proto::DisplayInfo;

use crate::font::{self, CELL_H, CELL_W};
use crate::geom::IRect;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    SelectDisplay(u8),
    SetQuality(u8),
    SetFit(bool),
    ToggleViewOnly,
    ToggleFullscreen,
    Disconnect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Header,
    Radio(bool),
    Check(bool),
    Button,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub kind: Kind,
    pub label: String,
    pub action: Option<Action>,
    pub enabled: bool,
}

impl Item {
    pub fn selectable(&self) -> bool {
        self.action.is_some() && self.enabled
    }

    fn header(label: &str) -> Item {
        Item { kind: Kind::Header, label: label.into(), action: None, enabled: true }
    }

    fn radio(label: String, on: bool, action: Action) -> Item {
        Item { kind: Kind::Radio(on), label, action: Some(action), enabled: true }
    }
}

/// What the menu reflects.
pub struct MenuState<'a> {
    pub displays: &'a [DisplayInfo],
    pub display: u8,
    pub quality: u8,
    pub fit: bool,
    pub view_only: bool,
    /// The host session was started view-only; control can't be enabled.
    pub view_only_locked: bool,
    pub fullscreen: bool,
}

const MAX_LABEL: usize = 44;

pub fn build_items(s: &MenuState) -> Vec<Item> {
    let mut v = vec![Item::header("Display")];
    for d in s.displays {
        let label =
            format!("{}: {} {}x{}{}", d.index, d.name, d.width, d.height, if d.primary { " (primary)" } else { "" });
        v.push(Item::radio(
            font::truncate(&font::sanitize(&label), MAX_LABEL),
            d.index == s.display,
            Action::SelectDisplay(d.index),
        ));
    }
    v.push(Item::header("Quality"));
    for (q, name) in [(0u8, "Lossless"), (1, "Balanced"), (2, "Speed")] {
        v.push(Item::radio(name.into(), s.quality == q, Action::SetQuality(q)));
    }
    v.push(Item::header("View"));
    v.push(Item::radio("Fit to window".into(), s.fit, Action::SetFit(true)));
    v.push(Item::radio("Actual size (1:1)".into(), !s.fit, Action::SetFit(false)));
    v.push(Item {
        kind: Kind::Check(s.view_only),
        label: if s.view_only_locked { "View only (set when connecting)".into() } else { "View only".into() },
        action: Some(Action::ToggleViewOnly),
        enabled: !s.view_only_locked,
    });
    v.push(Item {
        kind: Kind::Button,
        label: if s.fullscreen { "Leave fullscreen (F11)".into() } else { "Fullscreen (F11)".into() },
        action: Some(Action::ToggleFullscreen),
        enabled: true,
    });
    v.push(Item { kind: Kind::Button, label: "Disconnect".into(), action: Some(Action::Disconnect), enabled: true });
    v
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuLayout {
    pub rect: IRect,
    pub pad: i32,
    pub title_y: i32,
    pub footer_y: i32,
    /// One rect per item, full panel width.
    pub rows: Vec<IRect>,
}

impl MenuLayout {
    /// Item under window position `(x, y)`.
    pub fn hit(&self, x: f64, y: f64) -> Option<usize> {
        if !self.rect.contains(x, y) {
            return None;
        }
        self.rows.iter().position(|r| r.contains(x, y))
    }
}

/// Lay the panel out centered in a `win_w`×`win_h` window at `scale`.
pub fn layout(items: &[Item], title: &str, footer: &str, scale: i32, win_w: u32, win_h: u32) -> MenuLayout {
    let pad = 10 * scale;
    let row_h = (CELL_H + 6) * scale;
    let chars = items
        .iter()
        .map(|i| i.label.chars().count() + 6) // prefix + indent
        .chain([title.chars().count() + 2, footer.chars().count()])
        .max()
        .unwrap_or(20)
        .max(30) as i32;
    let w = chars * CELL_W * scale + 2 * pad;
    let title_h = row_h;
    let footer_h = row_h;
    let h = pad + title_h + items.len() as i32 * row_h + footer_h + pad;
    let x = (win_w as i32 - w) / 2;
    let y = (win_h as i32 - h) / 2;
    let x = x.max(0);
    let y = y.max(0);
    let mut rows = Vec::with_capacity(items.len());
    let mut ry = y + pad + title_h;
    for _ in items {
        rows.push(IRect::new(x + 1, ry, (w - 2) as u32, row_h as u32));
        ry += row_h;
    }
    MenuLayout {
        rect: IRect::new(x, y, w as u32, h as u32),
        pad,
        title_y: y + pad + (row_h - CELL_H * scale) / 2,
        footer_y: ry + (row_h - CELL_H * scale) / 2,
        rows,
    }
}

/// Next selectable item after `from` in direction `dir` (+1/-1), wrapping.
pub fn step(items: &[Item], from: Option<usize>, dir: i32) -> Option<usize> {
    let n = items.len() as i32;
    if n == 0 || !items.iter().any(Item::selectable) {
        return None;
    }
    let mut i = match (from, dir) {
        (Some(f), _) => f as i32,
        (None, d) if d > 0 => -1,
        (None, _) => n,
    };
    loop {
        i = (i + dir).rem_euclid(n);
        if items[i as usize].selectable() {
            return Some(i as usize);
        }
    }
}

#[derive(Default)]
pub struct Menu {
    pub open: bool,
    pub selected: Option<usize>,
}

impl Menu {
    pub fn toggle(&mut self, items: &[Item]) {
        self.open = !self.open;
        self.selected = if self.open { step(items, None, 1) } else { None };
    }

    pub fn close(&mut self) {
        self.open = false;
        self.selected = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn displays() -> Vec<DisplayInfo> {
        vec![
            DisplayInfo { index: 0, name: "Left".into(), x: 0, y: 0, width: 1920, height: 1080, primary: false },
            DisplayInfo { index: 1, name: "Main".into(), x: 1920, y: 0, width: 2560, height: 1440, primary: true },
        ]
    }

    fn state<'a>(d: &'a [DisplayInfo]) -> MenuState<'a> {
        MenuState {
            displays: d,
            display: 1,
            quality: 1,
            fit: true,
            view_only: false,
            view_only_locked: false,
            fullscreen: false,
        }
    }

    #[test]
    fn items_reflect_state() {
        let d = displays();
        let items = build_items(&state(&d));
        let radios: Vec<_> = items
            .iter()
            .filter_map(|i| if let Kind::Radio(on) = i.kind { Some((i.label.as_str(), on)) } else { None })
            .collect();
        assert_eq!(radios[0], ("0: Left 1920x1080", false));
        assert_eq!(radios[1], ("1: Main 2560x1440 (primary)", true));
        assert!(radios.contains(&("Balanced", true)));
        assert!(radios.contains(&("Lossless", false)));
        assert!(radios.contains(&("Fit to window", true)));
        assert!(radios.contains(&("Actual size (1:1)", false)));
        let last = items.last().unwrap();
        assert_eq!((last.label.as_str(), last.action), ("Disconnect", Some(Action::Disconnect)));
        // Headers are never selectable.
        assert!(items.iter().filter(|i| matches!(i.kind, Kind::Header)).all(|i| !i.selectable()));
    }

    #[test]
    fn locked_view_only_is_disabled() {
        let d = displays();
        let mut s = state(&d);
        s.view_only = true;
        s.view_only_locked = true;
        let items = build_items(&s);
        let vo = items.iter().find(|i| matches!(i.kind, Kind::Check(_))).unwrap();
        assert_eq!(vo.kind, Kind::Check(true));
        assert!(!vo.selectable());
    }

    #[test]
    fn layout_is_centered_and_hit_tests() {
        let d = displays();
        let items = build_items(&state(&d));
        let lay = layout(&items, "CrossShell viewer", "Esc closes", 1, 1280, 720);
        assert_eq!(lay.rows.len(), items.len());
        let cx = lay.rect.x + lay.rect.w as i32 / 2;
        assert!((cx - 640).abs() <= 1);
        // Every row is inside the panel and rows do not overlap.
        for w in lay.rows.windows(2) {
            assert_eq!(w[0].bottom(), w[1].y);
        }
        assert!(lay.rows.iter().all(|r| r.y >= lay.rect.y && r.bottom() <= lay.rect.bottom()));
        // Clicking the middle of row 1 hits item 1; outside hits nothing.
        let r = lay.rows[1];
        assert_eq!(lay.hit(r.x as f64 + 10.0, r.y as f64 + 3.0), Some(1));
        assert_eq!(lay.hit(2.0, 2.0), None);
        // Footer/title areas hit no row.
        assert_eq!(lay.hit(lay.rect.x as f64 + 5.0, lay.rect.y as f64 + 2.0), None);
    }

    #[test]
    fn layout_scales_and_clamps_in_small_windows() {
        let d = displays();
        let items = build_items(&state(&d));
        let lay = layout(&items, "t", "f", 2, 200, 100);
        assert!(lay.rect.x >= 0 && lay.rect.y >= 0);
        let lay1 = layout(&items, "t", "f", 1, 200, 100);
        assert_eq!(lay.rect.h, lay1.rect.h * 2);
    }

    #[test]
    fn keyboard_navigation_skips_headers_and_wraps() {
        let d = displays();
        let mut s = state(&d);
        s.view_only_locked = true; // disabled item must be skipped too
        let items = build_items(&s);
        let first = step(&items, None, 1).unwrap();
        assert!(items[first].selectable());
        assert_eq!(items[first].action, Some(Action::SelectDisplay(0)));
        // Walk forward through everything selectable and come back around.
        let mut seen = vec![first];
        let mut cur = first;
        for _ in 0..items.len() {
            cur = step(&items, Some(cur), 1).unwrap();
            if cur == first {
                break;
            }
            seen.push(cur);
        }
        assert!(seen.iter().all(|i| items[*i].selectable()));
        assert_eq!(seen.len(), items.iter().filter(|i| i.selectable()).count());
        // Backwards from the first wraps to the last (Disconnect).
        let last = step(&items, Some(first), -1).unwrap();
        assert_eq!(items[last].action, Some(Action::Disconnect));
        assert_eq!(step(&items, None, -1), Some(last));
        assert_eq!(step(&[], None, 1), None);
    }

    #[test]
    fn toggle_selects_first_item() {
        let d = displays();
        let items = build_items(&state(&d));
        let mut m = Menu::default();
        m.toggle(&items);
        assert!(m.open && m.selected.is_some());
        m.toggle(&items);
        assert!(!m.open && m.selected.is_none());
    }
}
