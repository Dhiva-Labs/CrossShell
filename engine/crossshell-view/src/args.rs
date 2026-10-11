//! Command line (see the module docs in `main.rs` for the contract with the
//! Flutter app) and the stdin token.

use std::path::PathBuf;

use anyhow::{anyhow, bail, Context};
use crossshell_proto::{from_hex, TOKEN_LEN};

pub const USAGE: &str = "\
crossshell-view — CrossShell remote-desktop viewer

USAGE:
    crossshell-view --port <local-port> [--title <peer name>] [--view-only]
                    [--quality 0|1|2] [--fps N] [--display N] [--no-clipboard]
    crossshell-view --port <p> --snapshot <out.png> [--frames N]
    crossshell-view --version

The 64-hex-char session token is read from stdin (one line). The viewer
connects to 127.0.0.1:<port>, normally an SSH local forward to the host agent.
Events are printed to stdout as JSON lines.

Window shortcuts: F11 or Ctrl+Alt+Enter = fullscreen, Ctrl+Alt+M = menu.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub port: u16,
    pub title: String,
    pub view_only: bool,
    /// 0 lossless, 1 balanced, 2 speed.
    pub quality: u8,
    pub fps: u8,
    pub display: u8,
    pub clipboard: bool,
    /// Headless mode: write the final framebuffer here.
    pub snapshot: Option<PathBuf>,
    pub frames: u32,
}

pub enum Parsed {
    Run(Args),
    Help,
    Version,
}

pub fn parse<I: IntoIterator<Item = String>>(argv: I) -> anyhow::Result<Parsed> {
    let mut port: Option<u16> = None;
    let mut a = Args {
        port: 0,
        title: String::new(),
        view_only: false,
        quality: 1,
        fps: 30,
        display: 0,
        clipboard: true,
        snapshot: None,
        frames: 30,
    };
    let mut it = argv.into_iter();
    while let Some(arg) = it.next() {
        // Accept `--flag=value` as well as `--flag value`.
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_owned(), Some(v.to_owned())),
            _ => (arg.clone(), None),
        };
        let mut value = |what: &str| -> anyhow::Result<String> {
            inline.clone().or_else(|| it.next()).ok_or_else(|| anyhow!("{what} needs a value"))
        };
        match flag.as_str() {
            "--port" => port = Some(value("--port")?.parse().context("bad --port")?),
            "--title" => a.title = value("--title")?,
            "--view-only" => a.view_only = true,
            "--no-clipboard" => a.clipboard = false,
            "--quality" => {
                a.quality = value("--quality")?
                    .parse()
                    .ok()
                    .filter(|q| *q <= 2)
                    .ok_or_else(|| anyhow!("--quality must be 0, 1 or 2"))?
            }
            "--fps" => {
                let n: u32 = value("--fps")?.parse().context("bad --fps")?;
                a.fps = n.clamp(1, 120) as u8;
            }
            "--display" => a.display = value("--display")?.parse().context("bad --display")?,
            "--snapshot" => a.snapshot = Some(PathBuf::from(value("--snapshot")?)),
            "--frames" => {
                a.frames = value("--frames")?
                    .parse()
                    .ok()
                    .filter(|n| *n >= 1)
                    .ok_or_else(|| anyhow!("--frames must be at least 1"))?
            }
            "--help" | "-h" => return Ok(Parsed::Help),
            "--version" | "-V" => return Ok(Parsed::Version),
            _ => bail!("unknown argument {arg:?}"),
        }
    }
    a.port = port.ok_or_else(|| anyhow!("--port is required"))?;
    if a.port == 0 {
        bail!("--port must be 1-65535");
    }
    Ok(Parsed::Run(a))
}

/// Parse the token line: 64 hex chars, surrounding whitespace ignored.
pub fn parse_token(line: &str) -> anyhow::Result<[u8; TOKEN_LEN]> {
    from_hex(line)
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| anyhow!("the session token on stdin must be {} hex characters", TOKEN_LEN * 2))
}

/// Read the token from stdin (one line; never from argv).
pub fn read_token() -> anyhow::Result<[u8; TOKEN_LEN]> {
    let mut line = String::new();
    std::io::stdin().read_line(&mut line).context("reading the token from stdin")?;
    parse_token(&line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> anyhow::Result<Args> {
        match parse(args.iter().map(|s| s.to_string()))? {
            Parsed::Run(a) => Ok(a),
            _ => bail!("not a run"),
        }
    }

    #[test]
    fn minimal_and_full() {
        let a = run(&["--port", "47950"]).unwrap();
        assert_eq!((a.port, a.quality, a.fps, a.display, a.view_only, a.clipboard), (47950, 1, 30, 0, false, true));
        assert_eq!(a.snapshot, None);
        let a = run(&[
            "--port",
            "9",
            "--title",
            "winbox",
            "--view-only",
            "--quality",
            "2",
            "--fps",
            "60",
            "--display",
            "1",
            "--snapshot",
            "x.png",
            "--frames",
            "5",
            "--no-clipboard",
        ])
        .unwrap();
        assert_eq!(a.title, "winbox");
        assert!(a.view_only && !a.clipboard);
        assert_eq!((a.quality, a.fps, a.display, a.frames), (2, 60, 1, 5));
        assert_eq!(a.snapshot, Some(PathBuf::from("x.png")));
    }

    #[test]
    fn equals_syntax_and_clamps() {
        let a = run(&["--port=12", "--title=a b", "--fps=500"]).unwrap();
        assert_eq!((a.port, a.title.as_str(), a.fps), (12, "a b", 120));
        assert_eq!(run(&["--port", "1", "--fps", "0"]).unwrap().fps, 1);
    }

    #[test]
    fn errors() {
        assert!(run(&[]).is_err());
        assert!(run(&["--port", "0"]).is_err());
        assert!(run(&["--port", "70000"]).is_err());
        assert!(run(&["--port", "1", "--quality", "3"]).is_err());
        assert!(run(&["--port", "1", "--frames", "0"]).is_err());
        assert!(run(&["--port", "1", "--bogus"]).is_err());
        assert!(run(&["--port"]).is_err());
        assert!(matches!(parse(["--help".to_string()]).unwrap(), Parsed::Help));
        assert!(matches!(parse(["--version".to_string()]).unwrap(), Parsed::Version));
    }

    #[test]
    fn token_parsing() {
        let hex = "ab".repeat(32);
        assert_eq!(parse_token(&format!("{hex}\n")).unwrap(), [0xab; 32]);
        assert_eq!(parse_token(&format!("  {}\r\n", hex.to_uppercase())).unwrap(), [0xab; 32]);
        assert!(parse_token("abcd").is_err());
        assert!(parse_token(&"zz".repeat(32)).is_err());
        assert!(parse_token("").is_err());
    }
}
