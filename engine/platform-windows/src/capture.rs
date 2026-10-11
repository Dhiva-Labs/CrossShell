//! Screen capture with DXGI Desktop Duplication.
//!
//! Each acquired desktop image is copied into a CPU-readable staging
//! texture and handed to the core while mapped; it is unmapped at the start
//! of the next call. The pointer is not part of the image: DXGI reports it
//! separately and [`CursorTracker`] turns that into viewer updates.

use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use crossshell_platform::{Capture, CapturedFrame, Capturer, CursorUpdate};
use windows::core::Interface;
use windows::Win32::Foundation::{E_ACCESSDENIED, HMODULE};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
    D3D11_CREATE_DEVICE_FLAG, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION, DXGI_MODE_ROTATION_ROTATE180, DXGI_MODE_ROTATION_ROTATE270,
    DXGI_MODE_ROTATION_ROTATE90, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutput5, IDXGIOutputDuplication, IDXGIResource,
    DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_DEVICE_REMOVED, DXGI_ERROR_DEVICE_RESET, DXGI_ERROR_MODE_CHANGE_IN_PROGRESS,
    DXGI_ERROR_NOT_CURRENTLY_AVAILABLE, DXGI_ERROR_SESSION_DISCONNECTED, DXGI_ERROR_UNSUPPORTED,
    DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_POINTER_SHAPE_INFO,
};

use crate::cursor::{CursorTracker, RawShape};
use crate::desktop;
use crate::displays;

/// Minimum gap between attempts to reopen a lost duplication, so a
/// full-screen app flipping modes can't make us spin on device creation.
const REOPEN_BACKOFF: Duration = Duration::from_millis(200);

/// Why a duplication can't be opened right now.
enum OpenError {
    /// Tell the viewer and retry later (secure desktop, display unplugged…).
    Unavailable(String),
    /// Transient, e.g. a mode change in progress: retry soon, silently.
    Retry(String),
    /// Broken: fails capturer creation; later on it becomes a notice too.
    Failed(anyhow::Error),
}

/// A D3D11 device on the adapter that scans out the display. Survives
/// desktop switches and mode changes; rebuilt when the display topology
/// changes (stale factory) or the GPU is reset.
struct Device {
    factory: IDXGIFactory1,
    output: IDXGIOutput,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
}

impl Device {
    fn open(display: &str) -> Result<Device, OpenError> {
        let out = displays::find_output(display)
            .map_err(OpenError::Failed)?
            .ok_or_else(|| OpenError::Unavailable(format!("The shared display ({display}) is no longer connected.")))?;
        let (mut device, mut context) = (None, None);
        // The device must live on the output's own adapter, or duplication
        // fails with DXGI_ERROR_UNSUPPORTED (hybrid-GPU laptops).
        unsafe {
            D3D11CreateDevice(
                &out.adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_FLAG(0),
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
        }
        .context("D3D11CreateDevice")
        .map_err(OpenError::Failed)?;
        let (Some(device), Some(context)) = (device, context) else {
            return Err(OpenError::Failed(anyhow!("D3D11CreateDevice returned no device")));
        };
        Ok(Device { factory: out.factory, output: out.output, device, context })
    }
}

struct Duplication {
    dupl: IDXGIOutputDuplication,
    rotation: DXGI_MODE_ROTATION,
    /// When it was opened, until the first image arrives.
    opened: Option<Instant>,
}

struct Staging {
    tex: ID3D11Texture2D,
    width: u32,
    height: u32,
    mapped: bool,
}

/// What [`DuplCapturer::acquire`] left behind for the caller to hand out.
enum Got {
    Nothing,
    /// The staging texture is mapped at `ptr`.
    Mapped {
        width: u32,
        height: u32,
        stride: usize,
        ptr: *const u8,
    },
    /// The upright image is in `rotated`.
    Rotated {
        width: u32,
        height: u32,
    },
}

/// Releases an acquired frame however the processing ends.
struct FrameGuard<'a>(&'a IDXGIOutputDuplication);

impl Drop for FrameGuard<'_> {
    fn drop(&mut self) {
        if let Err(e) = unsafe { self.0.ReleaseFrame() } {
            // ACCESS_LOST here resurfaces on the next AcquireNextFrame.
            log::debug!("ReleaseFrame: {e}");
        }
    }
}

pub(crate) struct DuplCapturer {
    display: String,
    dev: Option<Device>,
    dup: Option<Duplication>,
    staging: Option<Staging>,
    last_open: Option<Instant>,
    rotated: Vec<u8>,
    cursor: CursorTracker,
    shape_buf: Vec<u8>,
}

impl DuplCapturer {
    /// Fails only when capture can't work at all; a secure desktop or a
    /// transient condition gives a capturer that reports `Unavailable`
    /// until it can open the duplication.
    pub fn new(display: String) -> anyhow::Result<Self> {
        let mut c = DuplCapturer {
            display,
            dev: None,
            dup: None,
            staging: None,
            last_open: None,
            rotated: Vec::new(),
            cursor: CursorTracker::default(),
            shape_buf: Vec::new(),
        };
        match c.open() {
            Ok(()) => {}
            Err(OpenError::Unavailable(r) | OpenError::Retry(r)) => {
                log::info!("{}: capture not possible yet: {r}", c.display);
            }
            Err(OpenError::Failed(e)) => return Err(e.context(format!("capturing {}", c.display))),
        }
        Ok(c)
    }

    fn open(&mut self) -> Result<(), OpenError> {
        self.last_open = Some(Instant::now());
        self.dup = None;
        if self.dev.as_ref().is_some_and(|d| !unsafe { d.factory.IsCurrent() }.as_bool()) {
            log::info!("display configuration changed; recreating the capture device");
            self.drop_device();
        }
        if self.dev.is_none() {
            self.dev = Some(Device::open(&self.display)?);
        }
        let dev = self.dev.as_ref().expect("device just opened");
        let (dupl, api) = match duplicate(&dev.output, &dev.device) {
            Ok(d) => d,
            Err(e) => {
                if is_device_loss(&e) {
                    self.drop_device();
                }
                return Err(classify(e));
            }
        };
        let desc = unsafe { dupl.GetDesc() };
        if desc.ModeDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
            return Err(OpenError::Failed(anyhow!("unsupported desktop pixel format {:?}", desc.ModeDesc.Format)));
        }
        log::info!(
            "{}: duplicating {}x{} via {api}, rotation {}",
            self.display,
            desc.ModeDesc.Width,
            desc.ModeDesc.Height,
            desc.Rotation.0
        );
        self.dup = Some(Duplication { dupl, rotation: desc.Rotation, opened: Some(Instant::now()) });
        Ok(())
    }

    fn unmap(&mut self) {
        if let (Some(dev), Some(st)) = (&self.dev, &mut self.staging) {
            if st.mapped {
                unsafe { dev.context.Unmap(&st.tex, 0) };
                st.mapped = false;
            }
        }
    }

    fn drop_device(&mut self) {
        self.unmap();
        self.staging = None;
        self.dup = None;
        self.dev = None;
    }

    /// Forget a duplication that stopped working; the next call reopens it.
    fn reset(&mut self, e: &windows::core::Error) {
        if e.code() == DXGI_ERROR_ACCESS_LOST {
            log::info!(
                "{}: duplication lost (desktop switch, mode change or full-screen app); reopening",
                self.display
            );
        } else {
            log::warn!("{}: capture error: {e}; reopening", self.display);
        }
        self.unmap();
        self.dup = None;
        let removed = self.dev.as_ref().is_some_and(|d| unsafe { d.device.GetDeviceRemovedReason() }.is_err());
        if is_device_loss(e) || removed {
            self.drop_device();
        }
    }

    /// One AcquireNextFrame round trip. Errors (other than the timeout)
    /// mean the duplication must be reopened.
    fn acquire(&mut self, timeout: Duration) -> windows::core::Result<Got> {
        let (Some(dev), Some(dup)) = (&self.dev, &mut self.dup) else { return Ok(Got::Nothing) };
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut res: Option<IDXGIResource> = None;
        let ms = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        unsafe { dup.dupl.AcquireNextFrame(ms, &mut info, &mut res) }?;
        let frame = FrameGuard(&dup.dupl);

        if info.LastMouseUpdateTime != 0 {
            let p = info.PointerPosition;
            self.cursor.set_position(p.Visible.as_bool(), p.Position.x, p.Position.y);
        }
        if info.PointerShapeBufferSize > 0 {
            read_pointer_shape(&dup.dupl, info.PointerShapeBufferSize, &mut self.shape_buf, &mut self.cursor);
        }
        // LastPresentTime 0 = no new desktop image: only the pointer moved,
        // or this is the very first acquire of a duplication, whose surface
        // is still empty (all zero). On a still screen DXGI follows that up
        // with a full image one vsync later.
        if info.LastPresentTime == 0 {
            log::trace!("pointer-only update");
            return Ok(Got::Nothing);
        }
        if let Some(opened) = dup.opened.take() {
            log::debug!("{}: first image {:?} after opening", self.display, opened.elapsed());
        }
        let Some(res) = res else { return Ok(Got::Nothing) };
        let tex: ID3D11Texture2D = res.cast()?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { tex.GetDesc(&mut desc) };

        if self.staging.as_ref().is_none_or(|s| (s.width, s.height) != (desc.Width, desc.Height)) {
            self.staging = None;
            let sd = D3D11_TEXTURE2D_DESC {
                Width: desc.Width,
                Height: desc.Height,
                MipLevels: 1,
                ArraySize: 1,
                Format: desc.Format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut t = None;
            unsafe { dev.device.CreateTexture2D(&sd, None, Some(&mut t)) }?;
            let tex = t.ok_or_else(|| windows::core::Error::from_hresult(DXGI_ERROR_DEVICE_REMOVED))?;
            log::info!("{}: capturing {}x{} (surface)", self.display, desc.Width, desc.Height);
            self.staging = Some(Staging { tex, width: desc.Width, height: desc.Height, mapped: false });
        }
        let st = self.staging.as_mut().expect("staging just created");
        unsafe { dev.context.CopyResource(&st.tex, &tex) };
        // Release before mapping, like the DXGI sample and OBS: the copy is
        // already queued ahead of the release, and DWM gets the surface back
        // while we wait for the readback.
        drop(frame);

        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe { dev.context.Map(&st.tex, 0, D3D11_MAP_READ, 0, Some(&mut m)) }?;
        st.mapped = true;
        let (w, h, stride) = (st.width, st.height, m.RowPitch as usize);
        let ptr = m.pData as *const u8;
        let Some(degrees) = rotation_degrees(dup.rotation) else {
            return Ok(Got::Mapped { width: w, height: h, stride, ptr });
        };
        // Rotated displays hand out the image in the panel's native
        // orientation; turn it upright so frame pixels match the desktop.
        let src = unsafe { std::slice::from_raw_parts(ptr, stride * (h as usize - 1) + w as usize * 4) };
        let (rw, rh) = rotate(src, w as usize, h as usize, stride, degrees, &mut self.rotated);
        unsafe { dev.context.Unmap(&st.tex, 0) };
        st.mapped = false;
        Ok(Got::Rotated { width: rw as u32, height: rh as u32 })
    }
}

impl Drop for DuplCapturer {
    fn drop(&mut self) {
        self.unmap();
    }
}

impl Capturer for DuplCapturer {
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Capture<'_>> {
        self.unmap();
        if self.dup.is_none() {
            let since = self.last_open.map_or(REOPEN_BACKOFF, |t| t.elapsed());
            if since < REOPEN_BACKOFF {
                std::thread::sleep((REOPEN_BACKOFF - since).min(timeout));
                return Ok(Capture::Unchanged);
            }
            match self.open() {
                Ok(()) => {}
                Err(OpenError::Unavailable(r)) => return Ok(Capture::Unavailable(r)),
                Err(OpenError::Retry(r)) => {
                    log::debug!("{}: not ready: {r}", self.display);
                    std::thread::sleep(timeout);
                    return Ok(Capture::Unchanged);
                }
                Err(OpenError::Failed(e)) => {
                    log::warn!("{}: reopening capture failed: {e:#}", self.display);
                    return Ok(Capture::Unavailable(format!("Screen capture failed ({e:#}); retrying.")));
                }
            }
        }
        match self.acquire(timeout) {
            Ok(Got::Nothing) => Ok(Capture::Unchanged),
            Ok(Got::Mapped { width, height, stride, ptr }) => {
                // Valid until the Unmap at the start of the next call, which
                // needs `&mut self` and so outlives this borrow.
                let len = stride * (height as usize - 1) + width as usize * 4;
                let data = unsafe { std::slice::from_raw_parts(ptr, len) };
                Ok(Capture::Frame(CapturedFrame { width, height, stride, data }))
            }
            Ok(Got::Rotated { width, height }) => {
                Ok(Capture::Frame(CapturedFrame { width, height, stride: width as usize * 4, data: &self.rotated }))
            }
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => Ok(Capture::Unchanged),
            Err(e) => {
                self.reset(&e);
                Ok(Capture::Unchanged)
            }
        }
    }

    fn cursor(&mut self) -> Option<CursorUpdate> {
        self.cursor.take_update()
    }
}

/// `DuplicateOutput1` (Windows 10 1703+) converts HDR and wide-gamut
/// desktops to 8-bit BGRA for us, where the old call fails outright.
fn duplicate(
    output: &IDXGIOutput,
    device: &ID3D11Device,
) -> windows::core::Result<(IDXGIOutputDuplication, &'static str)> {
    if let Ok(o5) = output.cast::<IDXGIOutput5>() {
        match unsafe { o5.DuplicateOutput1(device, 0, &[DXGI_FORMAT_B8G8R8A8_UNORM]) } {
            Ok(d) => return Ok((d, "DuplicateOutput1")),
            // Secure desktop: the old call would be refused the same way.
            Err(e) if e.code() == E_ACCESSDENIED => return Err(e),
            Err(e) => log::debug!("DuplicateOutput1 failed ({e}); falling back to DuplicateOutput"),
        }
    }
    let o1: IDXGIOutput1 = output.cast()?;
    Ok((unsafe { o1.DuplicateOutput(device) }?, "DuplicateOutput"))
}

fn is_device_loss(e: &windows::core::Error) -> bool {
    e.code() == DXGI_ERROR_DEVICE_REMOVED || e.code() == DXGI_ERROR_DEVICE_RESET
}

fn classify(e: windows::core::Error) -> OpenError {
    let c = e.code();
    if c == E_ACCESSDENIED {
        if desktop::secure_desktop_active() {
            OpenError::Unavailable(desktop::SECURE_DESKTOP.into())
        } else {
            // Seen for a moment right after the secure desktop closes.
            OpenError::Unavailable("Windows denied access to the screen; retrying.".into())
        }
    } else if c == DXGI_ERROR_SESSION_DISCONNECTED {
        OpenError::Unavailable(
            "The Windows session is not attached to the screen (another user is signed in, \
             or a Remote Desktop session took it over)."
                .into(),
        )
    } else if c == DXGI_ERROR_NOT_CURRENTLY_AVAILABLE {
        OpenError::Unavailable("Too many apps are capturing this display right now.".into())
    } else if c == DXGI_ERROR_MODE_CHANGE_IN_PROGRESS || c == DXGI_ERROR_ACCESS_LOST || is_device_loss(&e) {
        OpenError::Retry(e.to_string())
    } else if c == DXGI_ERROR_UNSUPPORTED {
        OpenError::Failed(anyhow!("Desktop Duplication is not supported for this display: {e}"))
    } else {
        OpenError::Failed(anyhow::Error::new(e).context("DuplicateOutput"))
    }
}

fn read_pointer_shape(dupl: &IDXGIOutputDuplication, size: u32, buf: &mut Vec<u8>, cursor: &mut CursorTracker) {
    buf.resize(size as usize, 0);
    let mut needed = 0u32;
    let mut si = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
    match unsafe { dupl.GetFramePointerShape(size, buf.as_mut_ptr().cast(), &mut needed, &mut si) } {
        Ok(()) => cursor.set_shape(&RawShape {
            kind: si.Type,
            width: si.Width,
            height: si.Height,
            pitch: si.Pitch,
            hot_x: si.HotSpot.x,
            hot_y: si.HotSpot.y,
            data: buf,
        }),
        Err(e) => log::debug!("GetFramePointerShape: {e}"),
    }
}

fn rotation_degrees(r: DXGI_MODE_ROTATION) -> Option<u32> {
    match r {
        DXGI_MODE_ROTATION_ROTATE90 => Some(90),
        DXGI_MODE_ROTATION_ROTATE180 => Some(180),
        DXGI_MODE_ROTATION_ROTATE270 => Some(270),
        _ => None,
    }
}

/// Turn a 4-byte-per-pixel image in surface orientation upright, into
/// `dst` (tightly packed). Returns the upright width and height.
///
/// The mapping follows the dirty-rect transform of Microsoft's Desktop
/// Duplication sample: for ROTATE90 the upright image is the surface turned
/// 90° clockwise, for ROTATE270 counter-clockwise.
pub(crate) fn rotate(
    src: &[u8],
    sw: usize,
    sh: usize,
    stride: usize,
    degrees: u32,
    dst: &mut Vec<u8>,
) -> (usize, usize) {
    let (dw, dh) = if degrees == 180 { (sw, sh) } else { (sh, sw) };
    dst.resize(dw * dh * 4, 0);
    // Walk the destination in tiles so the transposed reads stay in cache.
    const TILE: usize = 32;
    for ty in (0..dh).step_by(TILE) {
        for tx in (0..dw).step_by(TILE) {
            for dy in ty..(ty + TILE).min(dh) {
                for dx in tx..(tx + TILE).min(dw) {
                    let (sx, sy) = match degrees {
                        90 => (dy, sh - 1 - dx),
                        180 => (sw - 1 - dx, sh - 1 - dy),
                        _ => (sw - 1 - dy, dx),
                    };
                    let s = sy * stride + sx * 4;
                    let d = (dy * dw + dx) * 4;
                    dst[d..d + 4].copy_from_slice(&src[s..s + 4]);
                }
            }
        }
    }
    (dw, dh)
}

#[cfg(test)]
mod tests {
    use super::rotate;

    /// 3x2 image, one byte per pixel label (A..F), padded stride.
    fn surface() -> Vec<u8> {
        let stride = 16;
        let mut v = vec![0xEE; stride * 2];
        for (i, label) in b"ABCDEF".iter().enumerate() {
            let (x, y) = (i % 3, i / 3);
            v[y * stride + x * 4..][..4].copy_from_slice(&[*label; 4]);
        }
        v
    }

    fn labels(img: &[u8]) -> String {
        img.chunks(4).map(|p| p[0] as char).collect()
    }

    #[test]
    fn rotate_90_turns_clockwise() {
        // ABC      DA
        // DEF  ->  EB
        //          FC
        let mut out = Vec::new();
        assert_eq!(rotate(&surface(), 3, 2, 16, 90, &mut out), (2, 3));
        assert_eq!(labels(&out), "DAEBFC");
    }

    #[test]
    fn rotate_180_and_270() {
        let mut out = Vec::new();
        assert_eq!(rotate(&surface(), 3, 2, 16, 180, &mut out), (3, 2));
        assert_eq!(labels(&out), "FEDCBA");
        assert_eq!(rotate(&surface(), 3, 2, 16, 270, &mut out), (2, 3));
        assert_eq!(labels(&out), "CFBEAD");
    }

    #[test]
    fn rotations_compose() {
        let mut once = Vec::new();
        let mut back = Vec::new();
        rotate(&surface(), 3, 2, 16, 90, &mut once);
        rotate(&once, 2, 3, 8, 270, &mut back);
        assert_eq!(labels(&back), "ABCDEF");
    }
}
