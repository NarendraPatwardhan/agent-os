//! Device filesystem - /dev/null, /dev/zero, /dev/random

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::bridge;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom,
};

/// Device types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DevType {
    Null,   // /dev/null - discards writes, EOF on read
    Zero,   // /dev/zero - infinite zeros
    Random, // /dev/random - random bytes from host
    Cons,   // /dev/cons - the terminal (Plan 9): writes go to stdout, read EOF
}

/// Device filesystem
pub struct DevFs {
    devices: BTreeMap<String, DevType>,
}

impl DevFs {
    pub fn new() -> Self {
        let mut devices = BTreeMap::new();
        devices.insert(String::from("/null"), DevType::Null);
        devices.insert(String::from("/zero"), DevType::Zero);
        devices.insert(String::from("/random"), DevType::Random);
        devices.insert(String::from("/cons"), DevType::Cons);

        Self { devices }
    }

    /// Normalize path
    fn normalize_path(&self, path: &KPath) -> String {
        let s = path.as_str();
        if s.is_empty() {
            String::from("/")
        } else {
            String::from(s)
        }
    }

    /// Get device by path
    fn get_device(&self, path: &str) -> Option<DevType> {
        // Handle both /dev/X and /X
        let clean_path = if path.starts_with("/dev") {
            String::from(&path[4..])
        } else {
            String::from(path)
        };

        self.devices.get(&clean_path).copied()
    }
}

/// File handle for device files
pub struct DevFileHandle {
    dev_type: DevType,
    offset: u64,
}

impl DevFileHandle {
    fn new(dev_type: DevType) -> Self {
        Self {
            dev_type,
            offset: 0,
        }
    }
}

impl FileHandle for DevFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        match self.dev_type {
            DevType::Null => {
                // EOF immediately
                Ok(0)
            }
            DevType::Zero => {
                // Fill with zeros
                for byte in buf.iter_mut() {
                    *byte = 0;
                }
                self.offset += buf.len() as u64;
                Ok(buf.len())
            }
            DevType::Random => {
                // Get random bytes from host
                unsafe {
                    bridge::mc_random(buf.as_mut_ptr(), buf.len());
                }
                self.offset += buf.len() as u64;
                Ok(buf.len())
            }
            // The console as a file (Plan 9 `/dev/cons`).
            // Reading returns EOF — terminal input is owned by the line
            // discipline, not a pull-from-fd source.
            DevType::Cons => Ok(0),
        }
    }

    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        match self.dev_type {
            DevType::Null => {
                // Discard all writes
                Ok(buf.len())
            }
            // `/dev/cons` write → the agent's terminal (stdout). Guests write LF;
            // the terminal layer adds the CR (ONLCR), like any other tty output.
            DevType::Cons => {
                crate::io::term_write_stdout(buf);
                Ok(buf.len())
            }
            DevType::Zero | DevType::Random => {
                // Cannot write to these devices
                Err(FsError::PermissionDenied)
            }
        }
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let new_offset = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => self.offset as i64 + n,
            SeekFrom::End(n) => {
                // Devices have no end
                if n < 0 { 0 } else { n as i64 }
            }
        };

        if new_offset < 0 {
            return Err(FsError::InvalidPath);
        }

        self.offset = new_offset as u64;
        Ok(self.offset)
    }

    fn stat(&self) -> Result<Metadata> {
        let size = match self.dev_type {
            DevType::Null | DevType::Cons => 0,
            DevType::Zero | DevType::Random => 0, // Infinite/variable size devices
        };

        Ok(Metadata::file(size))
    }
}

impl FileSystem for DevFs {
    fn open(
        &mut self,
        path: &KPath,
        flags: OpenFlags,
        _caller: CallerId,
    ) -> Result<Box<dyn FileHandle>> {
        let path_str = self.normalize_path(path);

        // Get device type
        let dev_type = self.get_device(&path_str).ok_or(FsError::NotFound)?;

        // Check write permissions
        if flags.write {
            match dev_type {
                DevType::Zero | DevType::Random => {
                    return Err(FsError::PermissionDenied);
                }
                // Null discards writes; cons forwards them to the terminal.
                DevType::Null | DevType::Cons => {}
            }
        }

        let handle = DevFileHandle::new(dev_type);
        Ok(Box::new(handle))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let path_str = self.normalize_path(path);
        if path_str == "/" || path_str == "/dev" {
            return Ok(Metadata::dir());
        }

        let dev_type = self.get_device(&path_str).ok_or(FsError::NotFound)?;

        let size = match dev_type {
            DevType::Null | DevType::Cons => 0,
            DevType::Zero | DevType::Random => 0,
        };

        Ok(Metadata::file(size))
    }

    fn readdir(&self, _path: &KPath, _caller: CallerId) -> Result<Vec<DirEntry>> {
        // List all devices
        let mut result = Vec::new();

        for (name, _dev_type) in &self.devices {
            let display_name = if name.starts_with('/') {
                String::from(&name[1..]) // Remove leading /
            } else {
                name.clone()
            };

            result.push(DirEntry {
                name: display_name,
                node_type: NodeType::File,
            });
        }

        Ok(result)
    }

    fn mkdir(&mut self, _path: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied) // Cannot create directories in /dev
    }

    fn unlink(&mut self, _path: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied) // Cannot delete devices
    }

    fn rename(&mut self, _from: &KPath, _to: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied) // Cannot rename devices
    }
}
