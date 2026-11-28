//! A journal: one append-only JSONL file per role, written under a lock and rotated by size,
//! read through cursors.

use std::fs::File;
use std::fs::OpenOptions;
use std::io::Read;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::path::PathBuf;

use anyhow::Result;
use serde::Deserialize;
use serde::Serialize;

/// Ids a cursor remembers, so a restart from 0 after a shrink or rotation repeats nothing.
const KEEP_IDS: usize = 256;

pub struct Journal {
    pub dir: PathBuf,
    /// The file name without `.jsonl`; a rotated file is `<stem>.<date>.jsonl`.
    pub stem: String,
    pub rotate_at: u64,
}

impl Journal {
    /// Today's `bus/<role>/inbox.jsonl`, rotated at 1 MiB.
    pub fn inbox(dir: impl Into<PathBuf>) -> Journal {
        Journal {
            dir: dir.into(),
            stem: "inbox".into(),
            rotate_at: 1 << 20,
        }
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(format!("{}.jsonl", self.stem))
    }

    /// Run f while holding the journal's lock (`<dir>/.lock`, shared with the shell writer's flock).
    pub fn locked<T>(
        &self,
        f: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        let lock = OpenOptions::new()
            .append(true)
            .create(true)
            .open(self.dir.join(".lock"))?;
        lock.lock()?;
        f()
    }

    /// Append one line under the lock, rotating the file first when it reached rotate_at.
    pub fn append(
        &self,
        line: &str,
    ) -> Result<()> {
        self.locked(|| self.append_unlocked(line))
    }

    pub(crate) fn append_unlocked(
        &self,
        line: &str,
    ) -> Result<()> {
        let path = self.path();
        if path.metadata().is_ok_and(|m| m.len() >= self.rotate_at) {
            let now = chrono::Local::now();
            let mut old = self
                .dir
                .join(format!("{}.{}.jsonl", self.stem, now.format("%Y%m%d")));
            if old.exists() {
                old = self.dir.join(format!(
                    "{}.{}.jsonl",
                    self.stem,
                    now.format("%Y%m%d-%H%M%S")
                ));
            }
            std::fs::rename(&path, old)?;
        }
        let mut file = OpenOptions::new().append(true).create(true).open(path)?;
        file.write_all(format!("{line}\n").as_bytes())?;

        Ok(())
    }

    /// Every complete line of the current file.
    pub fn lines(&self) -> Result<Vec<Vec<u8>>> {
        let data = match std::fs::read(self.path()) {
            Ok(data) => data,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let complete = data.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
        Ok(data[..complete]
            .split(|b| *b == b'\n')
            .filter(|line| !line.trim_ascii().is_empty())
            .map(|line| line.trim_ascii().to_vec())
            .collect())
    }
}

/// A reader's place in a journal: the byte offset after the last line it handled, the file's
/// inode (a rotated file starts again at 0) and the last ids it delivered.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Cursor {
    pub off: u64,
    pub ino: u64,
    pub ids: Vec<String>,
}

impl Cursor {
    pub fn load(path: &Path) -> Cursor {
        std::fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub fn save(
        &self,
        path: &Path,
    ) -> Result<()> {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, format!("{}\n", serde_json::to_string(self)?))?;
        std::fs::rename(tmp, path)?;

        Ok(())
    }

    pub fn seen(
        &self,
        id: &str,
    ) -> bool {
        self.ids.iter().any(|seen| seen == id)
    }

    fn add(
        &mut self,
        id: String,
    ) {
        self.ids.push(id);
        if self.ids.len() > KEEP_IDS {
            self.ids.drain(..self.ids.len() - KEEP_IDS);
        }
    }

    /// Hand each line appended since the cursor whose id_of is an id not seen yet to deliver,
    /// saving the cursor at path after each line. A deliver error leaves the line for the next
    /// step. Returns false when there was nothing to read.
    pub fn step(
        &mut self,
        journal: &Journal,
        path: &Path,
        id_of: impl Fn(&[u8]) -> Option<String>,
        mut deliver: impl FnMut(&[u8]) -> Result<()>,
    ) -> bool {
        let Ok(mut file) = File::open(journal.path()) else {
            return false;
        };
        let Ok(meta) = file.metadata() else {
            return false;
        };
        if meta.len() < self.off || (self.ino != 0 && meta.ino() != self.ino) {
            self.off = 0;
        }
        self.ino = meta.ino();
        if meta.len() == self.off {
            return false;
        }
        let mut buf = Vec::new();
        if file.seek(SeekFrom::Start(self.off)).is_err() || file.read_to_end(&mut buf).is_err() {
            return false;
        }
        let mut rest = &buf[..];
        while let Some(i) = rest.iter().position(|b| *b == b'\n') {
            let line = rest[..i].trim_ascii();
            rest = &rest[i + 1..];
            let id = id_of(line).filter(|id| !self.seen(id));
            if let Some(id) = id {
                if deliver(line).is_err() {
                    return false;
                }
                self.add(id);
            }
            self.off += i as u64 + 1;
            let _ = self.save(path);
        }
        true
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::envelope::Legacy;

    fn write(
        journal: &Journal,
        text: &str,
    ) {
        let mut file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(journal.path())
            .unwrap();
        file.write_all(text.as_bytes()).unwrap();
    }

    fn msg(
        journal: &Journal,
        id: &str,
        msg: &str,
    ) {
        write(
            journal,
            &format!(
                r#"{{"id":"{id}","ts":1700000000,"from":"test","to":"x1","alarm":"ping","msg":"{msg}"}}{}"#,
                "\n"
            ),
        );
    }

    // bus_test.go TestInboxResumeAndShrink
    #[test]
    fn test_resume_and_shrink() {
        let dir = std::env::temp_dir().join(format!("homund-cursor-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let journal = Journal::inbox(&dir);
        let at = dir.join("cursor");
        let id_of = |line: &[u8]| Legacy::parse(line).map(|m| m.id);
        let mut got = Vec::new();
        let mut deliver = |line: &[u8]| -> Result<()> {
            let m = Legacy::parse(line).unwrap();
            got.push(format!("{}={}", m.id, m.msg));
            Ok(())
        };
        msg(&journal, "a", "one");
        msg(&journal, "b", "two");
        let mut cursor = Cursor::load(&at);
        cursor.step(&journal, &at, id_of, &mut deliver);
        // a half-written line is left for later
        write(&journal, r#"{"id":"c","alarm":"ping","#);
        cursor.step(&journal, &at, id_of, &mut deliver);
        // a restart reads the saved cursor and repeats nothing
        let mut again = Cursor::load(&at);
        write(&journal, "\"msg\":\"three\"}\n");
        again.step(&journal, &at, id_of, &mut deliver);
        // rotation: the new file is shorter and starts with an old line
        std::fs::remove_file(journal.path()).unwrap();
        msg(&journal, "c", "three");
        msg(&journal, "d", "four");
        again.step(&journal, &at, id_of, &mut deliver);
        assert!(got.join(",") == "a=one,b=two,c=three,d=four", "{got:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn test_rotation() {
        let dir = std::env::temp_dir().join(format!("homund-rotate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let journal = Journal::inbox(&dir);
        write(&journal, &format!("{}\n", "x".repeat(1 << 20)));
        journal.append("fresh").unwrap();
        assert!(journal.lines().unwrap() == vec![b"fresh".to_vec()]);
        let rotated = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("inbox.2")
            })
            .count();
        assert!(rotated == 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
