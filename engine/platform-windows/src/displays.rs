//! Display enumeration: the DXGI outputs attached to the desktop, named via
//! the DisplayConfig API.
//!
//! The process is per-monitor DPI aware (see [`crate::init`]), so every
//! rectangle here is in physical pixels.

use std::collections::HashMap;

use anyhow::Context;
use windows::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, DISPLAYCONFIG_MODE_INFO,
    DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED, DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL,
    DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_SOURCE_DEVICE_NAME,
    DISPLAYCONFIG_TARGET_DEVICE_NAME, DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY, QDC_ONLY_ACTIVE_PATHS,
};
use windows::Win32::Foundation::{ERROR_SUCCESS, RECT};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput, DXGI_ERROR_NOT_FOUND, DXGI_OUTPUT_DESC,
};

use crate::DisplayInfo;

/// One shareable display.
#[derive(Debug, Clone)]
pub(crate) struct Output {
    pub info: DisplayInfo,
    /// GDI device name (`\\.\DISPLAY1`): how capturers and injectors find
    /// the output again after DXGI objects go stale.
    pub device: String,
}

/// A live DXGI output and the adapter that scans it out.
pub(crate) struct DxgiOutput {
    pub factory: IDXGIFactory1,
    pub adapter: IDXGIAdapter1,
    pub output: IDXGIOutput,
    pub desc: DXGI_OUTPUT_DESC,
}

pub(crate) fn wide_to_string(w: &[u16]) -> String {
    let n = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..n])
}

/// Outputs attached to the desktop: adapters in DXGI order, then outputs
/// in order per adapter. A fresh factory each time, because a factory's
/// output list is a snapshot that goes stale on topology changes.
pub(crate) fn attached_outputs() -> anyhow::Result<Vec<DxgiOutput>> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }.context("CreateDXGIFactory1")?;
    let mut found = Vec::new();
    for a in 0.. {
        let adapter = match unsafe { factory.EnumAdapters1(a) } {
            Ok(x) => x,
            Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
            Err(e) => return Err(e).context("EnumAdapters1"),
        };
        for o in 0.. {
            let Ok(output) = (unsafe { adapter.EnumOutputs(o) }) else { break };
            let desc = unsafe { output.GetDesc() }.context("IDXGIOutput::GetDesc")?;
            if !desc.AttachedToDesktop.as_bool() {
                continue;
            }
            // Hybrid-GPU drivers have been seen listing an output under two
            // adapters; the first one is the one that can duplicate it.
            if found.iter().any(|f: &DxgiOutput| f.desc.DeviceName == desc.DeviceName) {
                continue;
            }
            found.push(DxgiOutput { factory: factory.clone(), adapter: adapter.clone(), output, desc });
        }
    }
    Ok(found)
}

/// Find a desktop output by GDI device name.
pub(crate) fn find_output(device: &str) -> anyhow::Result<Option<DxgiOutput>> {
    Ok(attached_outputs()?.into_iter().find(|o| wide_to_string(&o.desc.DeviceName) == device))
}

pub(crate) fn enumerate() -> anyhow::Result<Vec<Output>> {
    let names = friendly_names();
    let outputs = attached_outputs()?;
    let mut list: Vec<Output> = outputs
        .iter()
        .take(u8::MAX as usize)
        .enumerate()
        .map(|(i, o)| {
            let device = wide_to_string(&o.desc.DeviceName);
            let r = o.desc.DesktopCoordinates;
            let name = names.get(&device).cloned().unwrap_or_else(|| short_device(&device).to_owned());
            Output {
                info: DisplayInfo {
                    index: i as u8,
                    name,
                    x: r.left,
                    y: r.top,
                    width: (r.right - r.left).max(0) as u32,
                    height: (r.bottom - r.top).max(0) as u32,
                    primary: contains_origin(&r),
                },
                device,
            }
        })
        .collect();

    // Two identical monitors share a friendly name; tell them apart.
    let mut count: HashMap<String, usize> = HashMap::new();
    for o in &list {
        *count.entry(o.info.name.clone()).or_default() += 1;
    }
    for o in &mut list {
        if count[&o.info.name] > 1 {
            o.info.name = format!("{} ({})", o.info.name, short_device(&o.device));
        }
    }
    Ok(list)
}

/// The primary display is the one whose top-left is the desktop origin.
fn contains_origin(r: &RECT) -> bool {
    r.left <= 0 && 0 < r.right && r.top <= 0 && 0 < r.bottom
}

/// `\\.\DISPLAY1` → `DISPLAY1`.
fn short_device(device: &str) -> &str {
    device.strip_prefix(r"\\.\").unwrap_or(device)
}

fn is_internal(t: DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY) -> bool {
    t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL
        || t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
        || t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED
}

/// GDI device name → monitor name ("DELL U2720Q", "Built-in display").
/// Best effort: an empty map just means device names are shown instead.
fn friendly_names() -> HashMap<String, String> {
    let mut names: HashMap<String, Vec<String>> = HashMap::new();
    let (mut n_paths, mut n_modes) = (0u32, 0u32);
    unsafe {
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut n_paths, &mut n_modes) != ERROR_SUCCESS {
            return HashMap::new();
        }
        let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); n_paths as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); n_modes as usize];
        if QueryDisplayConfig(
            QDC_ONLY_ACTIVE_PATHS,
            &mut n_paths,
            paths.as_mut_ptr(),
            &mut n_modes,
            modes.as_mut_ptr(),
            None,
        ) != ERROR_SUCCESS
        {
            return HashMap::new();
        }
        paths.truncate(n_paths as usize);

        for p in &paths {
            let mut src = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
            src.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            src.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
            src.header.adapterId = p.sourceInfo.adapterId;
            src.header.id = p.sourceInfo.id;
            if DisplayConfigGetDeviceInfo(&mut src.header) != 0 {
                continue;
            }
            let mut tgt = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
            tgt.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            tgt.header.size = size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
            tgt.header.adapterId = p.targetInfo.adapterId;
            tgt.header.id = p.targetInfo.id;
            if DisplayConfigGetDeviceInfo(&mut tgt.header) != 0 {
                continue;
            }
            let mut name = wide_to_string(&tgt.monitorFriendlyDeviceName);
            if name.is_empty() && is_internal(tgt.outputTechnology) {
                name = "Built-in display".into();
            }
            if name.is_empty() {
                continue;
            }
            // In clone mode several monitors show one source.
            let v = names.entry(wide_to_string(&src.viewGdiDeviceName)).or_default();
            if !v.contains(&name) {
                v.push(name);
            }
        }
    }
    names.into_iter().map(|(k, v)| (k, v.join(" + "))).collect()
}
