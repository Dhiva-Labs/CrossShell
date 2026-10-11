//! The viewer window: winit event handling, input forwarding, cursor,
//! overlays. Everything network-facing goes through [`Session`] channels, so
//! nothing here can block on the socket.

use std::collections::HashSet;
use std::num::NonZeroU32;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossshell_proto::{DisplayInfo, Message};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{Cursor, CursorIcon, CustomCursor, Fullscreen, Window, WindowId};

use crate::args::Args;
use crate::clip::ClipCmd;
use crate::events;
use crate::geom::{self, Layout};
use crate::input::{self, MoveLimiter, ScrollAccum, Shortcut};
use crate::keymap;
use crate::menu::{self, Action, Menu, MenuState};
use crate::net::{CloseReason, NetEvent, Session};
use crate::render::{self, BannerLevel, Canvas, Renderer};

pub enum UserEvent {
    Net(NetEvent),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Phase {
    Connecting,
    Waiting,
    Live,
    Disconnected(String),
}

struct Gfx {
    window: Arc<Window>,
    surface: softbuffer::Surface<Arc<Window>, Arc<Window>>,
    _context: softbuffer::Context<Arc<Window>>,
}

struct CursorImage {
    w: u16,
    h: u16,
    hot_x: u16,
    hot_y: u16,
    rgba: Vec<u8>,
}

enum RemoteCursor {
    Unknown,
    Hidden,
    Visible(CursorImage),
}

/// What the window's cursor is currently set to.
#[derive(Clone, Copy, PartialEq, Eq)]
enum AppliedCursor {
    Default,
    Hidden,
    /// Custom cursor, by shape generation.
    Custom(u32),
}

/// Window size before the first frame says what size it should be.
const START_SIZE: (f64, f64) = (960.0, 600.0);
/// Pixels from the window edge where 1:1 mode scrolls the view.
const EDGE_MARGIN: f64 = 6.0;
const EDGE_STEP: i32 = 14;
const EDGE_TICK: Duration = Duration::from_millis(16);
const MENU_TITLE: &str = "CrossShell viewer";

pub struct App {
    args: Args,
    session: Session,
    frame_pending: Arc<AtomicBool>,
    clip: Option<Sender<ClipCmd>>,
    gfx: Option<Gfx>,
    renderer: Renderer,
    pub exit_code: i32,
    user_closing: bool,

    phase: Phase,
    displays: Vec<DisplayInfo>,
    cur_display: u8,
    quality: u8,
    view_only: bool,
    view_only_locked: bool,
    fit: bool,
    pan: (i32, i32),
    frame_size: (u32, u32),
    sized: bool,

    cursor: RemoteCursor,
    custom_cursor: Option<CustomCursor>,
    cursor_gen: u32,
    applied_cursor: AppliedCursor,
    remote_pos: Option<(i32, i32)>,

    banner: Option<(BannerLevel, String)>,
    menu: Menu,
    rtt: Option<Duration>,
    draw_error_shown: bool,

    pointer: Option<(f64, f64)>,
    limiter: MoveLimiter,
    buttons_down: HashSet<u8>,
    keys_down: HashSet<u16>,
    swallowed: HashSet<KeyCode>,
    mods_down: HashSet<KeyCode>,
    scroll: ScrollAccum,
    edge_next: Instant,
}

impl App {
    pub fn new(args: Args, session: Session, frame_pending: Arc<AtomicBool>, clip: Option<Sender<ClipCmd>>) -> Self {
        App {
            quality: args.quality,
            view_only: args.view_only,
            view_only_locked: args.view_only,
            cur_display: args.display,
            args,
            session,
            frame_pending,
            clip,
            gfx: None,
            renderer: Renderer::new(),
            exit_code: 0,
            user_closing: false,
            phase: Phase::Connecting,
            displays: Vec::new(),
            fit: true,
            pan: (0, 0),
            frame_size: (0, 0),
            sized: false,
            cursor: RemoteCursor::Unknown,
            custom_cursor: None,
            cursor_gen: 0,
            applied_cursor: AppliedCursor::Default,
            remote_pos: None,
            banner: None,
            menu: Menu::default(),
            rtt: None,
            draw_error_shown: false,
            pointer: None,
            limiter: MoveLimiter::default(),
            buttons_down: HashSet::new(),
            keys_down: HashSet::new(),
            swallowed: HashSet::new(),
            mods_down: HashSet::new(),
            scroll: ScrollAccum::default(),
            edge_next: Instant::now(),
        }
    }

    // ------------------------------------------------------------ helpers

    fn window(&self) -> Option<&Arc<Window>> {
        self.gfx.as_ref().map(|g| &g.window)
    }

    fn request_redraw(&self) {
        if let Some(w) = self.window() {
            w.request_redraw();
        }
    }

    fn ui_scale(&self) -> i32 {
        self.window().map(|w| (w.scale_factor().round() as i32).clamp(1, 3)).unwrap_or(1)
    }

    fn layout(&self) -> Layout {
        let (w, h) = self.window().map(|w| (w.inner_size().width, w.inner_size().height)).unwrap_or((0, 0));
        Layout::compute(w, h, self.frame_size.0, self.frame_size.1, self.fit, self.pan)
    }

    fn live(&self) -> bool {
        self.phase == Phase::Live
    }

    fn can_send_input(&self) -> bool {
        self.live() && !self.view_only && !self.menu.open
    }

    fn send(&self, m: Message) {
        self.session.send(m);
    }

    fn ctrl(&self) -> bool {
        self.mods_down.contains(&KeyCode::ControlLeft) || self.mods_down.contains(&KeyCode::ControlRight)
    }

    fn alt(&self) -> bool {
        self.mods_down.contains(&KeyCode::AltLeft) || self.mods_down.contains(&KeyCode::AltRight)
    }

    fn fullscreen(&self) -> bool {
        self.window().is_some_and(|w| w.fullscreen().is_some())
    }

    /// The remote cursor is drawn by us (view-only, or no custom cursor to use).
    fn draws_cursor_itself(&self) -> bool {
        self.view_only || self.custom_cursor.is_none()
    }

    // ------------------------------------------------------------ closing

    fn user_close(&mut self, el: &ActiveEventLoop) {
        if self.user_closing {
            return;
        }
        self.user_closing = true;
        if let Phase::Disconnected(_) = self.phase {
            // Already reported; keep the failure exit code.
        } else {
            self.exit_code = 0;
            if self.live() && !self.view_only {
                self.send(Message::ReleaseAll);
            }
            events::closed("user");
        }
        self.session.close();
        el.exit();
    }

    fn on_closed(&mut self, reason: CloseReason) {
        if self.user_closing || reason == CloseReason::Local {
            return;
        }
        let text = reason.text();
        events::closed(&text);
        self.exit_code = 1;
        self.phase = Phase::Disconnected(text);
        self.menu.close();
        self.buttons_down.clear();
        self.keys_down.clear();
        self.apply_cursor();
        self.request_redraw();
    }

    // ------------------------------------------------------------ net events

    fn on_net(&mut self, el: &ActiveEventLoop, ev: NetEvent) {
        match ev {
            NetEvent::Waiting(msg) => {
                if self.phase == Phase::Connecting {
                    self.phase = Phase::Waiting;
                }
                events::waiting(&msg);
                self.request_redraw();
            }
            NetEvent::Connected { displays, display } => {
                if display != self.args.display {
                    let text = format!(
                        "display {} not found on the remote side, showing display {display}",
                        self.args.display
                    );
                    events::notice(1, &text);
                    self.banner = Some((BannerLevel::Warn, text));
                }
                events::connected(&displays);
                self.displays = displays;
                self.cur_display = display;
                self.phase = Phase::Live;
                if !self.view_only {
                    self.focus_sync();
                }
                self.request_redraw();
            }
            NetEvent::Frame { width, height, .. } => {
                self.frame_pending.store(false, Ordering::SeqCst);
                self.frame_size = (width, height);
                if !self.sized {
                    self.sized = true;
                    self.size_window_to_frame();
                }
                self.request_redraw();
            }
            NetEvent::CursorShape { width, height, hot_x, hot_y, rgba } => {
                self.on_cursor_shape(el, width, height, hot_x, hot_y, rgba);
            }
            NetEvent::CursorPos { x, y } => {
                self.remote_pos = Some((x, y));
                if self.view_only {
                    self.request_redraw();
                }
            }
            NetEvent::Displays(d) => {
                self.displays = d;
                if self.menu.open {
                    self.request_redraw();
                }
            }
            NetEvent::Notice { level, text } => {
                events::notice(level, &text);
                self.banner = (!text.is_empty()).then(|| (BannerLevel::from_wire(level), text));
                self.request_redraw();
            }
            NetEvent::Clipboard(text) => {
                if let Some(c) = &self.clip {
                    let _ = c.send(ClipCmd::Set(text));
                }
            }
            NetEvent::Rtt(d) => {
                self.rtt = Some(d);
                if self.menu.open {
                    self.request_redraw();
                }
            }
            NetEvent::Closed(reason) => self.on_closed(reason),
        }
    }

    fn on_cursor_shape(&mut self, el: &ActiveEventLoop, w: u16, h: u16, hot_x: u16, hot_y: u16, rgba: Vec<u8>) {
        self.cursor_gen = self.cursor_gen.wrapping_add(1);
        if w == 0 || h == 0 {
            self.cursor = RemoteCursor::Hidden;
            self.custom_cursor = None;
        } else {
            let (hot_x, hot_y) = (hot_x.min(w - 1), hot_y.min(h - 1));
            // winit custom cursors: nicest in control mode. If the platform
            // refuses, we hide the local cursor and draw the remote one.
            self.custom_cursor = winit::window::CustomCursor::from_rgba(rgba.clone(), w, h, hot_x, hot_y)
                .ok()
                .map(|src| el.create_custom_cursor(src));
            self.cursor = RemoteCursor::Visible(CursorImage { w, h, hot_x, hot_y, rgba });
        }
        self.apply_cursor();
        if self.draws_cursor_itself() {
            self.request_redraw();
        }
    }

    /// First frame: pick a window size that shows the remote at 1:1 if it
    /// fits in 85 % of the monitor, else scaled down to that.
    fn size_window_to_frame(&self) {
        let Some(w) = self.window() else { return };
        if w.fullscreen().is_some() || w.is_maximized() {
            return;
        }
        let mon = w.current_monitor().or_else(|| w.primary_monitor()).or_else(|| w.available_monitors().next());
        let (mw, mh) = mon.map(|m| (m.size().width, m.size().height)).unwrap_or((1920, 1080));
        let (fw, fh) = geom::initial_window_size(self.frame_size.0, self.frame_size.1, mw, mh);
        let _ = w.request_inner_size(PhysicalSize::new(fw, fh));
    }

    // ------------------------------------------------------------ cursor

    fn pointer_over_frame(&self) -> bool {
        match self.pointer {
            Some((x, y)) => self.layout().dst.contains(x, y) && !self.layout().is_empty(),
            None => false,
        }
    }

    fn apply_cursor(&mut self) {
        let want = if !self.live() || self.menu.open || self.view_only || !self.pointer_over_frame() {
            AppliedCursor::Default
        } else {
            match &self.cursor {
                RemoteCursor::Unknown => AppliedCursor::Default,
                RemoteCursor::Hidden => AppliedCursor::Hidden,
                RemoteCursor::Visible(_) if self.custom_cursor.is_some() => AppliedCursor::Custom(self.cursor_gen),
                // No custom cursor: hide the local one, we draw the remote's.
                RemoteCursor::Visible(_) => AppliedCursor::Hidden,
            }
        };
        if want == self.applied_cursor {
            return;
        }
        let Some(w) = self.window() else { return };
        match want {
            AppliedCursor::Default => {
                w.set_cursor_visible(true);
                w.set_cursor(Cursor::Icon(CursorIcon::Default));
            }
            AppliedCursor::Hidden => w.set_cursor_visible(false),
            AppliedCursor::Custom(_) => {
                if let Some(c) = &self.custom_cursor {
                    w.set_cursor_visible(true);
                    w.set_cursor(Cursor::Custom(c.clone()));
                }
            }
        }
        self.applied_cursor = want;
    }

    // ------------------------------------------------------------ input

    /// Forget held input and tell the remote side to let go of it.
    fn release_all(&mut self) {
        self.keys_down.clear();
        self.buttons_down.clear();
        self.scroll.reset();
        if self.live() && !self.view_only {
            self.send(Message::ReleaseAll);
        }
    }

    fn focus_sync(&self) {
        if self.view_only {
            return;
        }
        if let Some(c) = &self.clip {
            let _ = c.send(ClipCmd::FocusGained);
        }
    }

    fn on_focus(&mut self, focused: bool) {
        if focused {
            self.focus_sync();
        } else {
            self.release_all();
            self.mods_down.clear();
            self.swallowed.clear();
        }
    }

    fn on_key(&mut self, el: &ActiveEventLoop, event: KeyEvent) {
        let pressed = event.state == ElementState::Pressed;
        let code = match event.physical_key {
            PhysicalKey::Code(c) => Some(c),
            PhysicalKey::Unidentified(_) => None,
        };
        if let Some(c) = code {
            if matches!(c, KeyCode::ControlLeft | KeyCode::ControlRight | KeyCode::AltLeft | KeyCode::AltRight) {
                if pressed {
                    self.mods_down.insert(c);
                } else {
                    self.mods_down.remove(&c);
                }
            }
        }
        if let Phase::Disconnected(_) = self.phase {
            if pressed && matches!(code, Some(KeyCode::Escape | KeyCode::Enter | KeyCode::NumpadEnter)) {
                self.user_close(el);
            }
            return;
        }

        if let Some(c) = code {
            if pressed {
                if let Some(sc) = input::shortcut(c, self.ctrl(), self.alt()) {
                    if !event.repeat {
                        self.run_shortcut(sc);
                    }
                    self.swallowed.insert(c);
                    return;
                }
                if self.swallowed.contains(&c) {
                    return;
                }
            } else if self.swallowed.remove(&c) {
                return;
            }
        }

        if self.menu.open {
            if pressed {
                self.menu_key(el, code);
            }
            return;
        }
        if !self.can_send_input() {
            return;
        }
        let Some(evdev) = keymap::to_evdev(event.physical_key) else { return };
        if pressed {
            self.keys_down.insert(evdev);
        } else if !self.keys_down.remove(&evdev) {
            return; // its press was never sent
        }
        // Repeats go out as repeated downs.
        self.send(Message::Key { code: evdev, down: pressed });
    }

    fn run_shortcut(&mut self, sc: Shortcut) {
        // The remote has already seen Ctrl/Alt go down; let go of them.
        self.release_all();
        match sc {
            Shortcut::Fullscreen => self.toggle_fullscreen(),
            Shortcut::Menu => self.toggle_menu(),
        }
    }

    fn toggle_fullscreen(&mut self) {
        let Some(w) = self.window() else { return };
        let target = if w.fullscreen().is_some() { None } else { Some(Fullscreen::Borderless(None)) };
        w.set_fullscreen(target);
        self.request_redraw();
    }

    fn menu_state_items(&self) -> Vec<menu::Item> {
        menu::build_items(&MenuState {
            displays: &self.displays,
            display: self.cur_display,
            quality: self.quality,
            fit: self.fit,
            view_only: self.view_only,
            view_only_locked: self.view_only_locked,
            fullscreen: self.fullscreen(),
        })
    }

    fn menu_footer(&self) -> String {
        match self.rtt {
            Some(d) => format!("Esc closes   ping {} ms", d.as_millis()),
            None => "Esc closes".into(),
        }
    }

    fn menu_layout(&self, items: &[menu::Item]) -> menu::MenuLayout {
        let (w, h) = self.window().map(|w| (w.inner_size().width, w.inner_size().height)).unwrap_or((0, 0));
        menu::layout(items, MENU_TITLE, &self.menu_footer(), self.ui_scale(), w, h)
    }

    fn toggle_menu(&mut self) {
        if !self.live() {
            return;
        }
        if !self.menu.open {
            self.limiter.reset();
        }
        let items = self.menu_state_items();
        self.menu.toggle(&items);
        self.apply_cursor();
        self.request_redraw();
    }

    fn menu_key(&mut self, el: &ActiveEventLoop, code: Option<KeyCode>) {
        let items = self.menu_state_items();
        match code {
            Some(KeyCode::Escape) => self.menu.close(),
            Some(KeyCode::ArrowDown) => self.menu.selected = menu::step(&items, self.menu.selected, 1),
            Some(KeyCode::ArrowUp) => self.menu.selected = menu::step(&items, self.menu.selected, -1),
            Some(KeyCode::Enter | KeyCode::NumpadEnter | KeyCode::Space) => {
                if let Some(a) =
                    self.menu.selected.and_then(|i| items.get(i)).filter(|i| i.selectable()).and_then(|i| i.action)
                {
                    self.do_action(el, a);
                }
            }
            _ => {}
        }
        self.apply_cursor();
        self.request_redraw();
    }

    fn do_action(&mut self, el: &ActiveEventLoop, a: Action) {
        match a {
            Action::SelectDisplay(i) => {
                if i != self.cur_display {
                    self.cur_display = i;
                    self.send_select();
                    self.remote_pos = None;
                    self.limiter.reset();
                }
                self.menu.close();
            }
            Action::SetQuality(q) => {
                if q != self.quality {
                    self.quality = q;
                    self.send_select();
                }
            }
            Action::SetFit(fit) => self.set_fit(fit),
            Action::ToggleViewOnly => {
                if !self.view_only_locked {
                    self.view_only = !self.view_only;
                    if self.view_only {
                        self.keys_down.clear();
                        self.buttons_down.clear();
                    } else {
                        self.focus_sync();
                    }
                }
            }
            Action::ToggleFullscreen => {
                self.menu.close();
                self.toggle_fullscreen();
            }
            Action::Disconnect => {
                self.user_close(el);
                return;
            }
        }
        self.apply_cursor();
        self.request_redraw();
    }

    fn send_select(&self) {
        self.send(Message::SelectDisplay { display: self.cur_display, quality: self.quality, max_fps: self.args.fps });
    }

    fn set_fit(&mut self, fit: bool) {
        if fit == self.fit {
            return;
        }
        if !fit {
            // Entering 1:1: center on the remote cursor if known, else the
            // frame center.
            let (win_w, win_h) = self.window().map(|w| (w.inner_size().width, w.inner_size().height)).unwrap_or((0, 0));
            let focus = self.remote_pos.unwrap_or((self.frame_size.0 as i32 / 2, self.frame_size.1 as i32 / 2));
            self.pan = geom::pan_centered_on(focus.0, focus.1, win_w, win_h);
        }
        self.fit = fit;
    }

    fn on_cursor_moved(&mut self, pos: PhysicalPosition<f64>) {
        self.pointer = Some((pos.x, pos.y));
        if self.menu.open {
            let items = self.menu_state_items();
            let lay = self.menu_layout(&items);
            let hit = lay.hit(pos.x, pos.y).filter(|i| items[*i].selectable());
            if hit.is_some() && hit != self.menu.selected {
                self.menu.selected = hit;
                self.request_redraw();
            }
            return;
        }
        self.apply_cursor();
        if !self.can_send_input() {
            return;
        }
        if let Some(p) = self.remote_point(true) {
            if let Some(p) = self.limiter.push(Instant::now(), p) {
                self.send(Message::PointerMove { x: p.0, y: p.1 });
            }
        }
        if self.custom_cursor.is_none() {
            self.request_redraw(); // fallback cursor follows the pointer
        }
    }

    /// Frame pixel under the pointer. `None` in the letterbox unless a
    /// button is held (then the nearest edge pixel, so drags keep working).
    fn remote_point(&self, honor_buttons: bool) -> Option<(i32, i32)> {
        let (x, y) = self.pointer?;
        let lay = self.layout();
        if honor_buttons && !self.buttons_down.is_empty() {
            Some(lay.to_frame_clamped(x, y))
        } else {
            lay.to_frame(x, y)
        }
    }

    /// Put the remote pointer where the user sees it before a click/scroll.
    fn sync_pointer(&mut self, clamped: bool) -> Option<(i32, i32)> {
        let (x, y) = self.pointer?;
        let lay = self.layout();
        let p = if clamped { Some(lay.to_frame_clamped(x, y)) } else { lay.to_frame(x, y) }?;
        if let Some(p) = self.limiter.force(Instant::now(), p) {
            self.send(Message::PointerMove { x: p.0, y: p.1 });
        }
        Some(p)
    }

    fn on_mouse_button(&mut self, el: &ActiveEventLoop, state: ElementState, button: MouseButton) {
        let pressed = state == ElementState::Pressed;
        if self.menu.open {
            if pressed && button == MouseButton::Left {
                self.menu_click(el);
            }
            return;
        }
        if !self.can_send_input() {
            return;
        }
        let Some(b) = input::button_code(button) else { return };
        if pressed {
            if self.sync_pointer(false).is_none() {
                return; // clicks in the letterbox are ignored
            }
            self.buttons_down.insert(b);
            self.send(Message::PointerButton { button: b, down: true });
        } else if self.buttons_down.remove(&b) {
            self.sync_pointer(true);
            self.send(Message::PointerButton { button: b, down: false });
        }
    }

    fn menu_click(&mut self, el: &ActiveEventLoop) {
        let Some((x, y)) = self.pointer else { return };
        let items = self.menu_state_items();
        let lay = self.menu_layout(&items);
        if !lay.rect.contains(x, y) {
            self.menu.close();
            self.apply_cursor();
            self.request_redraw();
            return;
        }
        if let Some(a) = lay.hit(x, y).and_then(|i| items.get(i)).filter(|i| i.selectable()).and_then(|i| i.action) {
            self.do_action(el, a);
        }
    }

    fn on_wheel(&mut self, delta: MouseScrollDelta) {
        if !self.can_send_input() {
            return;
        }
        let Some((dx, dy)) = self.scroll.add(delta) else { return };
        if self.sync_pointer(false).is_none() {
            return; // wheel over the letterbox
        }
        self.send(Message::Scroll { dx, dy });
    }

    // ------------------------------------------------------------ timers

    /// Flush held pointer moves and scroll the 1:1 view when the pointer
    /// pushes against a window edge. Returns when to wake next.
    fn tick(&mut self, now: Instant) -> Option<Instant> {
        if let Some(p) = self.limiter.flush_due(now) {
            self.send(Message::PointerMove { x: p.0, y: p.1 });
        }
        let mut next = self.limiter.deadline();
        if let Some(t) = self.edge_pan(now) {
            next = Some(next.map_or(t, |n| n.min(t)));
        }
        next
    }

    fn edge_pan(&mut self, now: Instant) -> Option<Instant> {
        if self.fit || !self.can_send_input() {
            return None;
        }
        let (px, py) = self.pointer?;
        let (win_w, win_h) = self.window().map(|w| (w.inner_size().width, w.inner_size().height))?;
        let lay = self.layout();
        let (dx, dy) = geom::edge_pan_dir(px, py, win_w, win_h, EDGE_MARGIN);
        let can_x = (dx < 0 && lay.src.x > 0) || (dx > 0 && lay.src.right() < self.frame_size.0 as i32);
        let can_y = (dy < 0 && lay.src.y > 0) || (dy > 0 && lay.src.bottom() < self.frame_size.1 as i32);
        if !can_x && !can_y {
            return None;
        }
        if now < self.edge_next {
            return Some(self.edge_next);
        }
        self.edge_next = now + EDGE_TICK;
        self.pan =
            (lay.src.x + if can_x { dx * EDGE_STEP } else { 0 }, lay.src.y + if can_y { dy * EDGE_STEP } else { 0 });
        if let Some(p) = self.remote_point(true) {
            if let Some(p) = self.limiter.force(now, p) {
                self.send(Message::PointerMove { x: p.0, y: p.1 });
            }
        }
        self.request_redraw();
        Some(self.edge_next)
    }

    // ------------------------------------------------------------ drawing

    fn state_message(&self, have_frame: bool) -> Option<(String, String)> {
        match &self.phase {
            Phase::Connecting => Some(("Connecting...".into(), String::new())),
            Phase::Waiting => Some((
                "Waiting for the remote side...".into(),
                "The other machine may be showing a consent dialog. Approve it there.".into(),
            )),
            Phase::Disconnected(r) => Some((format!("Disconnected: {r}"), "Close this window or press Esc.".into())),
            Phase::Live if !have_frame => Some(("Waiting for the first frame...".into(), String::new())),
            Phase::Live => None,
        }
    }

    fn redraw(&mut self) {
        let Some(window) = self.window().cloned() else { return };
        let size = window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else { return };
        let scale = self.ui_scale();
        let shared = self.session.shared.clone();
        let fb = shared.frame.lock().unwrap();
        self.frame_size = (fb.width, fb.height);
        let lay = Layout::compute(size.width, size.height, fb.width, fb.height, self.fit, self.pan);
        let have_frame = !lay.is_empty();

        // Overlay data that needs `&self`, gathered before the buffer borrow.
        let cursor_at = self.cursor_overlay_pos(&lay);
        let state = self.state_message(have_frame);
        let menu_items = self.menu.open.then(|| self.menu_state_items());
        let menu_layout = menu_items.as_ref().map(|items| self.menu_layout(items));
        let footer = self.menu_footer();
        let dim = matches!(self.phase, Phase::Disconnected(_));

        let Some(gfx) = self.gfx.as_mut() else { return };
        if gfx.surface.resize(w, h).is_err() {
            return;
        }
        let Ok(mut buffer) = gfx.surface.buffer_mut() else { return };
        let mut canvas = Canvas::new(&mut buffer, size.width, size.height);

        if let Err(e) = self.renderer.draw_frame(&mut canvas, &fb, &lay) {
            if !self.draw_error_shown {
                self.draw_error_shown = true;
                eprintln!("crossshell-view: drawing failed: {e:#}");
            }
        }
        drop(fb);
        if dim {
            canvas.dim_rect(geom::IRect::new(0, 0, size.width, size.height));
        }
        if let (RemoteCursor::Visible(c), Some((x, y))) = (&self.cursor, cursor_at) {
            canvas.blit_rgba(x - c.hot_x as i32, y - c.hot_y as i32, c.w as u32, c.h as u32, &c.rgba);
        }
        if let Some((level, text)) = &self.banner {
            render::draw_banner(&mut canvas, *level, text, scale);
        }
        if let (Some(items), Some(ml)) = (&menu_items, &menu_layout) {
            render::draw_menu(&mut canvas, items, ml, self.menu.selected, MENU_TITLE, &footer, scale);
        }
        if let Some((title, detail)) = &state {
            render::draw_message(&mut canvas, title, detail, scale);
        }
        if let Err(e) = buffer.present() {
            if !self.draw_error_shown {
                self.draw_error_shown = true;
                eprintln!("crossshell-view: presenting failed: {e}");
            }
        }
    }

    /// Where to composite the remote cursor (window coordinates of its
    /// hotspot), or `None` if the window's own cursor shows it.
    fn cursor_overlay_pos(&self, lay: &Layout) -> Option<(i32, i32)> {
        if !self.live()
            || lay.is_empty()
            || !matches!(self.cursor, RemoteCursor::Visible(_))
            || !self.draws_cursor_itself()
        {
            return None;
        }
        if self.view_only {
            let (x, y) = self.remote_pos?;
            let (wx, wy) = lay.to_window(x as f64, y as f64);
            // Skip positions outside the visible part of the frame.
            lay.dst.contains(wx, wy).then(|| (wx.round() as i32, wy.round() as i32))
        } else {
            // Control mode without a custom cursor: follow the local pointer.
            let (px, py) = self.pointer?;
            (!self.menu.open && lay.dst.contains(px, py)).then(|| (px.round() as i32, py.round() as i32))
        }
    }
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.gfx.is_some() {
            return;
        }
        let title = if self.args.title.trim().is_empty() {
            "Remote desktop \u{2014} CrossShell".to_owned()
        } else {
            format!("{} \u{2014} CrossShell", self.args.title.trim())
        };
        #[allow(unused_mut)]
        let mut attrs = Window::default_attributes()
            .with_title(title)
            .with_inner_size(LogicalSize::new(START_SIZE.0, START_SIZE.1))
            .with_min_inner_size(LogicalSize::new(320.0, 200.0));
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            use winit::platform::wayland::WindowAttributesExtWayland;
            use winit::platform::x11::WindowAttributesExtX11;
            attrs = WindowAttributesExtWayland::with_name(attrs, "crossshell-view", "crossshell-view");
            attrs = WindowAttributesExtX11::with_name(attrs, "crossshell-view", "CrossShell");
        }
        let window = match el.create_window(attrs) {
            Ok(w) => Arc::new(w),
            Err(e) => {
                let msg = format!("cannot create the window: {e}");
                eprintln!("crossshell-view: {msg}");
                events::closed(&msg);
                self.exit_code = 1;
                self.user_closing = true;
                self.session.close();
                el.exit();
                return;
            }
        };
        let gfx = softbuffer::Context::new(window.clone()).and_then(|ctx| {
            softbuffer::Surface::new(&ctx, window.clone()).map(|surface| Gfx {
                window: window.clone(),
                surface,
                _context: ctx,
            })
        });
        match gfx {
            Ok(g) => self.gfx = Some(g),
            Err(e) => {
                let msg = format!("cannot set up drawing: {e}");
                eprintln!("crossshell-view: {msg}");
                events::closed(&msg);
                self.exit_code = 1;
                self.user_closing = true;
                self.session.close();
                el.exit();
                return;
            }
        }
        self.request_redraw();
    }

    fn user_event(&mut self, el: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::Net(ev) => self.on_net(el, ev),
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => self.user_close(el),
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => {
                self.apply_cursor();
                self.request_redraw();
            }
            WindowEvent::Focused(f) => self.on_focus(f),
            // Synthetic events are winit replaying held keys on focus
            // changes; focus loss already released everything.
            WindowEvent::KeyboardInput { event, is_synthetic: false, .. } => self.on_key(el, event),
            WindowEvent::CursorMoved { position, .. } => self.on_cursor_moved(position),
            WindowEvent::CursorLeft { .. } => {
                self.pointer = None;
                self.apply_cursor();
                if self.custom_cursor.is_none() {
                    self.request_redraw();
                }
            }
            WindowEvent::MouseInput { state, button, .. } => self.on_mouse_button(el, state, button),
            WindowEvent::MouseWheel { delta, .. } => self.on_wheel(delta),
            _ => {}
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        let next = self.tick(Instant::now());
        el.set_control_flow(match next {
            Some(t) => ControlFlow::WaitUntil(t),
            None => ControlFlow::Wait,
        });
    }
}
