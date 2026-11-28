//! `homund session relay <cmd> [args...]`: run an interactive claude on a pty, passing the
//! terminal through unchanged, and type `/compact` into it when the user's Emacs asks; what
//! container/compact-relay does. The request is "<epoch> <word>" in
//! COMPACT_DIR/emacs-request/request (a directory only the user's Emacs can write); the word must
//! be in ALLOWED and nothing from the file is ever typed. It goes in only while the busy status
//! (BUSY_STATUS, default ~/claude/.services/busy/status) says idle, within 20 s, and the answer
//! lands in COMPACT_DIR/emacs-result as "<epoch> ok" or "<epoch> refused: why". Without a
//! terminal, or when the pty fails, the command runs directly.

use std::ffi::CString;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicI32;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

use super::cut;
use super::home;
use super::now;
use super::write_atomic;

const ALLOWED: [(&str, &[u8]); 1] = [("compact", b"/compact")];
const WAIT: f64 = 20.0;

fn dir(
    key: &str,
    fallback: &str,
) -> PathBuf {
    std::env::var_os(key).filter(|v| !v.is_empty()).map_or_else(
        || home().join("claude/.services").join(fallback),
        PathBuf::from,
    )
}

/// The allowlisted word of the newest fresh request, once, typed when idle.
pub struct Requests {
    request: PathBuf,
    result: PathBuf,
    busy: PathBuf,
    seen: Option<String>,
    pending: Option<(i64, &'static str)>,
}

impl Requests {
    pub fn from_env() -> Self {
        let compact = dir("COMPACT_DIR", "compact");
        let mut r = Self {
            request: compact.join("emacs-request/request"),
            result: compact.join("emacs-result"),
            busy: dir("BUSY_STATUS", "busy/status"),
            seen: None,
            pending: None,
        };
        r.seen = r.read(); // a request left from before this start is not typed
        r
    }

    fn read(&self) -> Option<String> {
        let bytes = fs::read(&self.request).ok()?;
        Some(cut(&String::from_utf8_lossy(&bytes), 64).trim().to_owned())
    }

    fn idle(&self) -> bool {
        fs::read_to_string(&self.busy)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .is_some_and(|v| v.get("state").and_then(|s| s.as_str()) == Some("idle"))
    }

    pub fn answer(
        &self,
        stamp: i64,
        text: &str,
    ) {
        let _ = write_atomic(&self.result, &format!("{stamp} {text}\n"));
    }

    /// Take a new request, answer a stale or bad one; the text and stamp when it is time to type.
    pub fn poll(&mut self) -> Option<(&'static [u8], i64)> {
        let line = self.read();
        if line.is_some() && line != self.seen {
            self.seen.clone_from(&line);
            let line = line.unwrap_or_default();
            let (stamp, word) = line.split_once(' ')?;
            let digits =
                (1..=12).contains(&stamp.len()) && stamp.bytes().all(|b| b.is_ascii_digit());
            let lower =
                (1..=16).contains(&word.len()) && word.bytes().all(|b| b.is_ascii_lowercase());
            if !digits || !lower {
                return None;
            }
            let stamp: i64 = stamp.parse().ok()?;
            match ALLOWED.iter().find(|(w, _)| *w == word) {
                None => self.answer(stamp, "refused: not an allowed command"),
                Some(_) if !(0.0..=60.0).contains(&(now() - stamp as f64)) => {
                    self.answer(stamp, "refused: stale request");
                }
                Some((w, _)) => self.pending = Some((stamp, w)),
            }
        }
        let (stamp, word) = self.pending?;
        if self.idle() {
            self.pending = None;
            return ALLOWED
                .iter()
                .find(|(w, _)| *w == word)
                .map(|(_, text)| (*text, stamp));
        }
        if now() - stamp as f64 > WAIT {
            self.pending = None;
            self.answer(stamp, "refused: The manager is busy");
        }
        None
    }
}

static WINCH: AtomicBool = AtomicBool::new(false);
static FORWARD: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_winch(_: libc::c_int) {
    WINCH.store(true, Ordering::SeqCst);
}

extern "C" fn on_forward(number: libc::c_int) {
    FORWARD.store(number, Ordering::SeqCst);
}

fn exec(argv: &[CString]) -> ! {
    let mut ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    // SAFETY: a NULL-terminated argv of NUL-terminated strings.
    unsafe {
        libc::execvp(ptrs[0], ptrs.as_ptr());
        libc::_exit(127)
    }
}

fn winsize(
    src: libc::c_int,
    dst: libc::c_int,
) {
    // SAFETY: TIOCGWINSZ/TIOCSWINSZ with a winsize struct of our own.
    unsafe {
        let mut size: libc::winsize = std::mem::zeroed();
        if libc::ioctl(src, libc::TIOCGWINSZ, &mut size) == 0 {
            libc::ioctl(dst, libc::TIOCSWINSZ, &size);
        }
    }
}

fn write_all(
    fd: libc::c_int,
    mut data: &[u8],
) {
    while !data.is_empty() {
        // SAFETY: writing from a live slice.
        let n = unsafe { libc::write(fd, data.as_ptr().cast(), data.len()) };
        if n <= 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        data = &data[n as usize..];
    }
}

fn relay(argv: &[CString]) -> i32 {
    // SAFETY: termios and forkpty calls on our own descriptors; the child only execs.
    unsafe {
        let mut saved: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut saved) != 0 {
            exec(argv); // no relay: the plain command, as without it
        }
        let mut master: libc::c_int = -1;
        let pid = libc::forkpty(
            &mut master,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        );
        if pid < 0 {
            exec(argv);
        }
        if pid == 0 {
            exec(argv);
        }
        winsize(0, master);
        libc::signal(libc::SIGWINCH, on_winch as *const () as libc::sighandler_t);
        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::signal(sig, on_forward as *const () as libc::sighandler_t);
        }
        let mut raw = saved;
        libc::cfmakeraw(&mut raw);
        libc::tcsetattr(0, libc::TCSAFLUSH, &raw);
        let mut reqs = Requests::from_env();
        let mut typing: Vec<(Instant, &[u8], Option<i64>)> = vec![];
        let mut stdin_open = true;
        let mut last: Option<Instant> = None;
        let mut buf = vec![0u8; 65536];
        loop {
            let sig = FORWARD.swap(0, Ordering::SeqCst);
            if sig != 0 {
                libc::kill(pid, sig);
            }
            if WINCH.swap(false, Ordering::SeqCst) {
                winsize(0, master);
            }
            if last.is_none_or(|t| t.elapsed() >= Duration::from_secs(1)) {
                last = Some(Instant::now());
                if let Some((text, stamp)) = reqs.poll() {
                    let at = Instant::now();
                    typing.push((at, text, None));
                    typing.push((at + Duration::from_millis(400), b"\r", Some(stamp)));
                }
            }
            while typing.first().is_some_and(|t| t.0 <= Instant::now()) {
                let (_, data, stamp) = typing.remove(0);
                write_all(master, data);
                if let Some(stamp) = stamp {
                    reqs.answer(stamp, "ok");
                }
            }
            let mut fds = [
                libc::pollfd {
                    fd: if stdin_open { 0 } else { -1 },
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: master,
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            if libc::poll(fds.as_mut_ptr(), 2, 200) < 0 {
                continue; // EINTR
            }
            if stdin_open && fds[0].revents != 0 {
                let n = libc::read(0, buf.as_mut_ptr().cast(), buf.len());
                if n > 0 {
                    write_all(master, &buf[..n as usize]);
                } else {
                    stdin_open = false;
                }
            }
            if fds[1].revents != 0 {
                let n = libc::read(master, buf.as_mut_ptr().cast(), buf.len());
                if n <= 0 {
                    break;
                }
                write_all(1, &buf[..n as usize]);
            }
        }
        libc::tcsetattr(0, libc::TCSADRAIN, &saved);
        let mut status = 0;
        while libc::waitpid(pid, &mut status, 0) < 0 {
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return 1;
            }
        }
        if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else {
            128 + libc::WTERMSIG(status)
        }
    }
}

/// start.sh starts this in the background, where stdin is /dev/null and stdout may be
/// redirected, though the container's pty is its controlling terminal: use that for either one
/// that is not a tty. False when there is none (then the command runs plain).
fn controlling_tty() -> bool {
    // SAFETY: open/isatty/dup2/close on plain descriptors.
    unsafe {
        let fd = libc::open(c"/dev/tty".as_ptr(), libc::O_RDWR);
        if fd < 0 {
            return false;
        }
        for std in [0, 1] {
            if libc::isatty(std) == 0 {
                libc::dup2(fd, std);
            }
        }
        libc::close(fd);
    }
    true
}

pub fn main(args: &[String]) -> ExitCode {
    if args.is_empty() {
        eprintln!("usage: homund session relay CMD [ARGS...]");
        return ExitCode::from(2);
    }
    let Ok(argv) = args
        .iter()
        .map(|a| CString::new(a.as_str()))
        .collect::<Result<Vec<_>, _>>()
    else {
        eprintln!("homund session relay: an argument holds a NUL byte");
        return ExitCode::from(2);
    };
    // SAFETY: isatty on the standard descriptors.
    let ttys = unsafe { libc::isatty(0) == 1 && libc::isatty(1) == 1 };
    if !ttys && !controlling_tty() {
        exec(&argv);
    }
    ExitCode::from(relay(&argv).clamp(0, 255) as u8)
}
