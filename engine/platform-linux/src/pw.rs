//! PipeWire screen-cast consumer shared by the Mutter and portal backends.
//!
//! Each capturer runs a PipeWire main loop on its own thread. The `process`
//! callback converts the newest buffer to packed BGRX and parks it in a
//! one-slot mailbox; [`PwCapturer::next_frame`] takes it from there, so a
//! slow consumer only ever sees the latest frame. Buffers are negotiated as
//! shared memory (no DMA-BUF modifiers are offered).

use std::any::Any;
use std::os::fd::OwnedFd;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context as _};
use crossshell_platform::{Capture, CapturedFrame, Capturer, CursorShape, CursorUpdate};
use pipewire as pw;
use pw::spa;
use spa::param::video::{VideoFormat, VideoInfoRaw};
use spa::pod::{ChoiceValue, Object, Pod, Property, Value};
use spa::sys as spa_sys;
use spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Fraction, Id, Rectangle, SpaTypes};

use crate::convert::{self, Channels};
use crate::input::SharedGeometry;

/// Where to find the stream.
pub struct PwSource {
    /// Connection from `OpenPipeWireRemote` (portal); `None` = the user's
    /// default PipeWire daemon (Mutter streams live there).
    pub remote: Option<OwnedFd>,
    pub node_id: u32,
}

/// How long to wait for the PipeWire thread to connect.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Largest cursor bitmap asked for (bytes of metadata, see `CURSOR_META_SIZE` in spa).
const fn cursor_meta_size(w: usize, h: usize) -> i32 {
    (std::mem::size_of::<spa_sys::spa_meta_cursor>() + std::mem::size_of::<spa_sys::spa_meta_bitmap>() + w * h * 4) as i32
}

#[derive(Default)]
struct State {
    /// Newest converted frame not yet handed out: (pixels, width, height).
    frame: Option<(Vec<u8>, u32, u32)>,
    /// Recycled pixel buffer.
    spare: Vec<u8>,
    /// Cursor changes not yet handed out.
    cursor: CursorUpdate,
    /// Negotiated buffer size.
    format: Option<(u32, u32)>,
    /// Fatal stream error; ends the session.
    error: Option<String>,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    cv: Condvar,
}

impl Shared {
    fn fail(&self, e: String) {
        let mut st = self.state.lock().unwrap();
        st.error.get_or_insert(e);
        self.cv.notify_all();
    }
}

pub struct PwCapturer {
    shared: Arc<Shared>,
    frame: Vec<u8>,
    quit: pw::channel::Sender<()>,
    thread: Option<JoinHandle<()>>,
    /// Keeps the D-Bus session behind the stream alive.
    _session: Arc<dyn Any + Send + Sync>,
}

impl PwCapturer {
    pub fn start(src: PwSource, geometry: SharedGeometry, session: Arc<dyn Any + Send + Sync>) -> anyhow::Result<Self> {
        let shared = Arc::new(Shared::default());
        let (quit, quit_rx) = pw::channel::channel::<()>();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<anyhow::Result<()>>();
        let thread = {
            let shared = shared.clone();
            std::thread::Builder::new().name("cs-pipewire".into()).spawn(move || {
                let node = src.node_id;
                if let Err(e) = run_loop(src, shared.clone(), geometry, quit_rx, &ready_tx) {
                    log::warn!("pipewire stream for node {node}: {e:#}");
                    shared.fail(format!("{e:#}"));
                    let _ = ready_tx.send(Err(e));
                }
            })?
        };
        let me = PwCapturer { shared, frame: Vec::new(), quit, thread: Some(thread), _session: session };
        match ready_rx.recv_timeout(CONNECT_TIMEOUT) {
            Ok(Ok(())) => Ok(me),
            Ok(Err(e)) => Err(e),
            Err(_) => bail!("timed out connecting to PipeWire"),
        }
    }

    /// Wait until the producer has agreed on a format; returns the buffer size.
    pub fn wait_format(&self, timeout: Duration) -> anyhow::Result<(u32, u32)> {
        let deadline = Instant::now() + timeout;
        let mut st = self.shared.state.lock().unwrap();
        loop {
            if let Some(e) = &st.error {
                bail!("{e}");
            }
            if let Some(f) = st.format {
                return Ok(f);
            }
            let now = Instant::now();
            if now >= deadline {
                bail!("no video format from the compositor within {timeout:?}");
            }
            st = self.shared.cv.wait_timeout(st, deadline - now).unwrap().0;
        }
    }
}

impl Drop for PwCapturer {
    fn drop(&mut self) {
        let _ = self.quit.send(());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Capturer for PwCapturer {
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Capture<'_>> {
        let deadline = Instant::now() + timeout;
        let mut st = self.shared.state.lock().unwrap();
        loop {
            if let Some(e) = &st.error {
                bail!("screen cast stream ended: {e}");
            }
            if let Some((data, w, h)) = st.frame.take() {
                st.spare = std::mem::replace(&mut self.frame, data);
                drop(st);
                return Ok(Capture::Frame(CapturedFrame {
                    width: w,
                    height: h,
                    stride: w as usize * 4,
                    data: &self.frame,
                }));
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(Capture::Unchanged);
            }
            st = self.shared.cv.wait_timeout(st, deadline - now).unwrap().0;
        }
    }

    fn cursor(&mut self) -> Option<CursorUpdate> {
        let u = std::mem::take(&mut self.shared.state.lock().unwrap().cursor);
        (u != CursorUpdate::default()).then_some(u)
    }
}

/// Per-stream state owned by the PipeWire thread.
struct StreamData {
    shared: Arc<Shared>,
    geometry: SharedGeometry,
    info: Option<(Channels, u32, u32)>,
    warned_dmabuf: bool,
}

fn run_loop(
    src: PwSource,
    shared: Arc<Shared>,
    geometry: SharedGeometry,
    quit_rx: pw::channel::Receiver<()>,
    ready: &std::sync::mpsc::Sender<anyhow::Result<()>>,
) -> anyhow::Result<()> {
    let mainloop = pw::main_loop::MainLoopRc::new(None).context("creating PipeWire main loop")?;
    let context = pw::context::ContextBox::new(mainloop.loop_(), None).context("creating PipeWire context")?;
    let core = match src.remote {
        Some(fd) => context.connect_fd(fd, None),
        None => context.connect(None),
    }
    .context("connecting to PipeWire")?;

    let _core_listener = {
        let shared = shared.clone();
        let ml = mainloop.downgrade();
        core.add_listener_local()
            .error(move |id, _seq, res, msg| {
                // id 0 is the core itself: the connection is gone.
                if id == 0 {
                    shared.fail(format!("PipeWire connection error {res}: {msg}"));
                    if let Some(ml) = ml.upgrade() {
                        ml.quit();
                    }
                }
            })
            .register()
    };

    let stream = pw::stream::StreamBox::new(
        &core,
        "crossshell-capture",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )?;

    let data = StreamData { shared: shared.clone(), geometry, info: None, warned_dmabuf: false };
    let ml = mainloop.downgrade();
    let _listener = stream
        .add_local_listener_with_user_data(data)
        .state_changed(move |_, d, old, new| {
            log::debug!("pipewire stream: {old:?} -> {new:?}");
            let gone = match &new {
                pw::stream::StreamState::Error(e) => Some(format!("stream error: {e}")),
                pw::stream::StreamState::Unconnected => Some("the compositor closed the stream".to_owned()),
                _ => None,
            };
            if let Some(e) = gone {
                d.shared.fail(e);
                if let Some(ml) = ml.upgrade() {
                    ml.quit();
                }
            }
        })
        .param_changed(|stream, d, id, param| {
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let Some(param) = param else { return };
            if let Err(e) = on_format(stream, d, param) {
                d.shared.fail(format!("{e:#}"));
            }
        })
        .process(on_process)
        .register()?;

    let format = serialize(enum_format())?;
    let mut params = [Pod::from_bytes(&format).ok_or_else(|| anyhow!("bad format pod"))?];
    stream
        .connect(
            spa::utils::Direction::Input,
            Some(src.node_id),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .context("connecting PipeWire stream")?;

    let ml = mainloop.downgrade();
    let _quit = quit_rx.attach(mainloop.loop_(), move |()| {
        if let Some(ml) = ml.upgrade() {
            ml.quit();
        }
    });
    let _ = ready.send(Ok(()));
    log::debug!("pipewire: consuming node {}", src.node_id);
    mainloop.run();
    let _ = stream.disconnect();
    Ok(())
}

fn serialize(v: Value) -> anyhow::Result<Vec<u8>> {
    Ok(spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &v)
        .map_err(|e| anyhow!("serializing pod: {e:?}"))?
        .0
        .into_inner())
}

/// 32-bit RGB formats we can convert, best first.
const FORMATS: [(VideoFormat, Channels); 8] = [
    (VideoFormat::BGRx, Channels::BGRX),
    (VideoFormat::BGRA, Channels::BGRA),
    (VideoFormat::RGBx, Channels::RGBX),
    (VideoFormat::RGBA, Channels::RGBA),
    (VideoFormat::xRGB, Channels::XRGB),
    (VideoFormat::ARGB, Channels::ARGB),
    (VideoFormat::xBGR, Channels::XBGR),
    (VideoFormat::ABGR, Channels::ABGR),
];

fn channels(f: u32) -> Option<Channels> {
    FORMATS.iter().find(|(v, _)| v.as_raw() == f).map(|&(_, c)| c)
}

fn prop(key: u32, value: Value) -> Property {
    Property::new(key, value)
}

/// EnumFormat: raw video in any of [`FORMATS`], any size and rate. No
/// modifier property, so producers fall back to shared memory.
fn enum_format() -> Value {
    use spa::param::format::{FormatProperties as F, MediaSubtype, MediaType};
    let ids: Vec<Id> = FORMATS.iter().map(|(f, _)| Id(f.as_raw())).collect();
    Value::Object(Object {
        type_: SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties: vec![
            prop(F::MediaType.as_raw(), Value::Id(Id(MediaType::Video.as_raw()))),
            prop(F::MediaSubtype.as_raw(), Value::Id(Id(MediaSubtype::Raw.as_raw()))),
            prop(
                F::VideoFormat.as_raw(),
                Value::Choice(ChoiceValue::Id(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Enum { default: ids[0], alternatives: ids.clone() },
                ))),
            ),
            prop(
                F::VideoSize.as_raw(),
                Value::Choice(ChoiceValue::Rectangle(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range {
                        default: Rectangle { width: 1920, height: 1080 },
                        min: Rectangle { width: 1, height: 1 },
                        max: Rectangle { width: 16384, height: 16384 },
                    },
                ))),
            ),
            prop(
                F::VideoFramerate.as_raw(),
                Value::Choice(ChoiceValue::Fraction(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range {
                        default: Fraction { num: 0, denom: 1 },
                        min: Fraction { num: 0, denom: 1 },
                        max: Fraction { num: 1000, denom: 1 },
                    },
                ))),
            ),
        ],
    })
}

/// Buffer and metadata params sent once the format is fixed: shared memory
/// only, plus header, crop and cursor metadata.
fn buffer_params() -> anyhow::Result<Vec<Vec<u8>>> {
    let meta = |kind: u32, size: Value| {
        Value::Object(Object {
            type_: SpaTypes::ObjectParamMeta.as_raw(),
            id: spa::param::ParamType::Meta.as_raw(),
            properties: vec![prop(spa_sys::SPA_PARAM_META_type, Value::Id(Id(kind))), prop(spa_sys::SPA_PARAM_META_size, size)],
        })
    };
    let buffers = Value::Object(Object {
        type_: SpaTypes::ObjectParamBuffers.as_raw(),
        id: spa::param::ParamType::Buffers.as_raw(),
        properties: vec![prop(
            spa_sys::SPA_PARAM_BUFFERS_dataType,
            Value::Int((1 << spa_sys::SPA_DATA_MemFd) | (1 << spa_sys::SPA_DATA_MemPtr)),
        )],
    });
    [
        buffers,
        meta(spa_sys::SPA_META_Header, Value::Int(std::mem::size_of::<spa_sys::spa_meta_header>() as i32)),
        meta(spa_sys::SPA_META_VideoCrop, Value::Int(std::mem::size_of::<spa_sys::spa_meta_region>() as i32)),
        meta(
            spa_sys::SPA_META_Cursor,
            Value::Choice(ChoiceValue::Int(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Range {
                    default: cursor_meta_size(64, 64),
                    min: cursor_meta_size(1, 1),
                    max: cursor_meta_size(1024, 1024),
                },
            ))),
        ),
    ]
    .into_iter()
    .map(serialize)
    .collect()
}

fn on_format(stream: &pw::stream::Stream, d: &mut StreamData, param: &Pod) -> anyhow::Result<()> {
    let (mt, mst) = spa::param::format_utils::parse_format(param).map_err(|e| anyhow!("bad format: {e:?}"))?;
    if mt != spa::param::format::MediaType::Video || mst != spa::param::format::MediaSubtype::Raw {
        bail!("compositor offered a non-raw video stream");
    }
    let mut info = VideoInfoRaw::new();
    info.parse(param).map_err(|e| anyhow!("bad video format: {e:?}"))?;
    let ch = channels(info.format().as_raw())
        .ok_or_else(|| anyhow!("unsupported pixel format {:?}", info.format()))?;
    let size = info.size();
    log::info!("pipewire: negotiated {:?} {}x{}", info.format(), size.width, size.height);
    d.info = Some((ch, size.width, size.height));
    d.geometry.lock().unwrap().buffer = (size.width, size.height);
    {
        let mut st = d.shared.state.lock().unwrap();
        st.format = Some((size.width, size.height));
        d.shared.cv.notify_all();
    }

    let bufs = buffer_params()?;
    let mut pods: Vec<&Pod> = bufs.iter().filter_map(|b| Pod::from_bytes(b)).collect();
    stream.update_params(&mut pods).context("updating buffer params")?;
    Ok(())
}

fn on_process(stream: &pw::stream::Stream, d: &mut StreamData) {
    // Skip to the newest queued buffer; hand older ones straight back.
    let mut buf = unsafe { stream.dequeue_raw_buffer() };
    if buf.is_null() {
        return;
    }
    loop {
        let next = unsafe { stream.dequeue_raw_buffer() };
        if next.is_null() {
            break;
        }
        unsafe { stream.queue_raw_buffer(buf) };
        buf = next;
    }
    unsafe {
        let spa_buf = (*buf).buffer;
        if !spa_buf.is_null() {
            consume(d, spa_buf);
        }
        stream.queue_raw_buffer(buf);
    }
}

/// Safety: `b` is a valid buffer dequeued from the stream.
unsafe fn consume(d: &mut StreamData, b: *mut spa_sys::spa_buffer) {
    let Some((ch, fw, fh)) = d.info else { return };

    let crop = {
        let r = spa_sys::spa_buffer_find_meta_data(b, spa_sys::SPA_META_VideoCrop, std::mem::size_of::<spa_sys::spa_meta_region>())
            as *const spa_sys::spa_meta_region;
        if r.is_null() { None } else { Some((*r).region) }
    };
    let (cx, cy, cw, ch_) = match crop {
        Some(r) if r.size.width > 0 && r.size.height > 0 => {
            let x = r.position.x.clamp(0, fw as i32) as u32;
            let y = r.position.y.clamp(0, fh as i32) as u32;
            (x, y, r.size.width.min(fw - x), r.size.height.min(fh - y))
        }
        _ => (0, 0, fw, fh),
    };
    d.geometry.lock().unwrap().crop = (cx as i32, cy as i32);

    let cursor = parse_cursor(b, (cx as i32, cy as i32));

    let header = spa_sys::spa_buffer_find_meta_data(b, spa_sys::SPA_META_Header, std::mem::size_of::<spa_sys::spa_meta_header>())
        as *const spa_sys::spa_meta_header;
    let corrupted = !header.is_null() && (*header).flags & spa_sys::SPA_META_HEADER_FLAG_CORRUPTED != 0;

    let mut pixels: Option<Vec<u8>> = None;
    if !corrupted && (*b).n_datas > 0 && cw > 0 && ch_ > 0 {
        let data = &*(*b).datas;
        let chunk = &*data.chunk;
        // A zero-sized or corrupted chunk carries only cursor metadata.
        let has_frame = chunk.size > 0 && chunk.flags & spa_sys::SPA_CHUNK_FLAG_CORRUPTED as i32 == 0;
        log::trace!(
            "pipewire: buffer type {} size {} flags {:#x} stride {} maxsize {} mapped {}",
            data.type_,
            chunk.size,
            chunk.flags,
            chunk.stride,
            data.maxsize,
            !data.data.is_null()
        );
        if has_frame && data.data.is_null() {
            if !d.warned_dmabuf {
                d.warned_dmabuf = true;
                log::error!("pipewire: buffer type {} is not mapped (DMA-BUF?); cannot read frames", data.type_);
            }
            d.shared.fail("the compositor sent frames this host cannot read (unmapped DMA-BUF)".into());
            return;
        }
        if has_frame {
            let offset = (chunk.offset % data.maxsize.max(1)) as usize;
            let avail = (data.maxsize as usize).saturating_sub(offset).min(chunk.size as usize);
            let src = std::slice::from_raw_parts((data.data as *const u8).add(offset), avail);
            let stride = if chunk.stride > 0 { chunk.stride as usize } else { fw as usize * 4 };
            let start = cy as usize * stride + cx as usize * 4;
            let mut out = std::mem::take(&mut d.shared.state.lock().unwrap().spare);
            if start < src.len() && convert::to_bgrx(&src[start..], stride, cw as usize, ch_ as usize, ch, &mut out) {
                pixels = Some(out);
            } else {
                log::debug!("pipewire: short buffer ({} bytes, stride {stride}) for {cw}x{ch_}", src.len());
            }
        }
    }

    if pixels.is_none() && cursor.is_none() {
        return;
    }
    let mut st = d.shared.state.lock().unwrap();
    if let Some(px) = pixels {
        if let Some((old, _, _)) = st.frame.replace((px, cw, ch_)) {
            st.spare = old;
        }
    }
    if let Some(c) = cursor {
        if c.shape.is_some() {
            st.cursor.shape = c.shape;
        }
        if c.position.is_some() {
            st.cursor.position = c.position;
        }
    }
    d.shared.cv.notify_all();
}

/// Read `SPA_META_Cursor`. Position is made relative to the crop origin.
///
/// Safety: `b` is a valid buffer.
unsafe fn parse_cursor(b: *mut spa_sys::spa_buffer, crop: (i32, i32)) -> Option<CursorUpdate> {
    let meta = spa_sys::spa_buffer_find_meta(b, spa_sys::SPA_META_Cursor);
    if meta.is_null() || (*meta).data.is_null() {
        return None;
    }
    let size = (*meta).size as usize;
    let bytes = std::slice::from_raw_parts((*meta).data as *const u8, size);
    parse_cursor_meta(bytes, crop)
}

fn read_u32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_ne_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

fn read_i32(b: &[u8], at: usize) -> Option<i32> {
    read_u32(b, at).map(|v| v as i32)
}

/// Parse a cursor metadata blob (`spa_meta_cursor`, optionally followed by
/// a `spa_meta_bitmap` and its pixels).
fn parse_cursor_meta(m: &[u8], crop: (i32, i32)) -> Option<CursorUpdate> {
    // struct spa_meta_cursor { u32 id, flags; spa_point position, hotspot; u32 bitmap_offset; }
    let id = read_u32(m, 0)?;
    if id == 0 {
        return None; // no cursor information in this buffer
    }
    let (px, py) = (read_i32(m, 8)?, read_i32(m, 12)?);
    let (hx, hy) = (read_i32(m, 16)?, read_i32(m, 20)?);
    let bitmap_offset = read_u32(m, 24)? as usize;
    let mut u = CursorUpdate { shape: None, position: Some((px - crop.0, py - crop.1)) };
    if bitmap_offset < std::mem::size_of::<spa_sys::spa_meta_cursor>() {
        return Some(u);
    }
    // struct spa_meta_bitmap { u32 format; spa_rectangle size; i32 stride; u32 offset; }
    let bm = m.get(bitmap_offset..)?;
    let format = read_u32(bm, 0)?;
    let (w, h) = (read_u32(bm, 4)?, read_u32(bm, 8)?);
    let stride = read_i32(bm, 12)?;
    let offset = read_u32(bm, 16)? as usize;
    if w == 0 || h == 0 {
        u.shape = Some(None); // empty sprite: cursor hidden
        return Some(u);
    }
    let Some(chs) = channels(format) else { return Some(u) };
    if offset < std::mem::size_of::<spa_sys::spa_meta_bitmap>() || w > 1024 || h > 1024 {
        return Some(u);
    }
    let stride = if stride > 0 { stride as usize } else { w as usize * 4 };
    let pixels = bm.get(offset..)?;
    if let Some(rgba) = convert::cursor_to_rgba(pixels, stride, w as usize, h as usize, chs) {
        u.shape = Some(Some(CursorShape {
            width: w as u16,
            height: h as u16,
            hot_x: hx.clamp(0, w as i32 - 1) as u16,
            hot_y: hy.clamp(0, h as i32 - 1) as u16,
            rgba,
        }));
    }
    Some(u)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cursor_blob(id: u32, pos: (i32, i32), hot: (i32, i32), bitmap: Option<(u32, u32, u32, &[u8])>) -> Vec<u8> {
        let mut m = Vec::new();
        for v in [id, 0, pos.0 as u32, pos.1 as u32, hot.0 as u32, hot.1 as u32] {
            m.extend_from_slice(&v.to_ne_bytes());
        }
        let off = if bitmap.is_some() { 28u32 } else { 0 };
        m.extend_from_slice(&off.to_ne_bytes());
        if let Some((format, w, h, px)) = bitmap {
            for v in [format, w, h, w * 4, 20] {
                m.extend_from_slice(&v.to_ne_bytes());
            }
            m.extend_from_slice(px);
        }
        m
    }

    #[test]
    fn layouts_match_spa() {
        assert_eq!(std::mem::size_of::<spa_sys::spa_meta_cursor>(), 28);
        assert_eq!(std::mem::size_of::<spa_sys::spa_meta_bitmap>(), 20);
    }

    #[test]
    fn cursor_position_only() {
        let m = cursor_blob(1, (100, 50), (0, 0), None);
        let u = parse_cursor_meta(&m, (10, 5)).unwrap();
        assert_eq!(u, CursorUpdate { shape: None, position: Some((90, 45)) });
        assert!(parse_cursor_meta(&cursor_blob(0, (1, 1), (0, 0), None), (0, 0)).is_none());
    }

    #[test]
    fn cursor_bitmap_and_hidden_cursor() {
        let rgba = VideoFormat::RGBA.as_raw();
        let px = [255, 0, 0, 255, 0, 0, 0, 0];
        let u = parse_cursor_meta(&cursor_blob(1, (3, 4), (1, 0), Some((rgba, 2, 1, &px))), (0, 0)).unwrap();
        let shape = u.shape.unwrap().unwrap();
        assert_eq!((shape.width, shape.height, shape.hot_x, shape.hot_y), (2, 1, 1, 0));
        assert_eq!(shape.rgba, px);
        // Mutter's "empty sprite": bitmap present but zeroed.
        let u = parse_cursor_meta(&cursor_blob(1, (3, 4), (0, 0), Some((0, 0, 0, &[]))), (0, 0)).unwrap();
        assert_eq!(u.shape, Some(None));
        // Truncated pixel data: position only.
        let u = parse_cursor_meta(&cursor_blob(1, (3, 4), (0, 0), Some((rgba, 2, 2, &px))), (0, 0)).unwrap();
        assert_eq!(u.shape, None);
        assert_eq!(u.position, Some((3, 4)));
    }

    #[test]
    fn format_pods_serialize() {
        assert!(Pod::from_bytes(&serialize(enum_format()).unwrap()).is_some());
        for p in buffer_params().unwrap() {
            assert!(Pod::from_bytes(&p).is_some());
        }
        assert_eq!(channels(VideoFormat::BGRx.as_raw()), Some(Channels::BGRX));
        assert_eq!(channels(VideoFormat::NV12.as_raw()), None);
    }
}
