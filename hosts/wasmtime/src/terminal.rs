//! Raw-terminal handling for the CLI's interactive mode.
//!
//! Wraps `crossterm`'s raw mode so the interactive session can read individual
//! key events without line buffering. Enabling raw mode is best-effort: when
//! there is no TTY (e.g. piped input under test) we fall back to non-raw mode
//! rather than failing, so the same code path still runs non-interactively. The
//! `Drop` impl restores the terminal on the way out.

use crossterm::{
    event::{self, Event, KeyEvent},
    terminal::{disable_raw_mode, enable_raw_mode},
};
use std::io;

pub struct Terminal {
    raw_mode: bool,
}

impl Terminal {
    pub fn new() -> io::Result<Self> {
        // Try to enable raw mode, but handle the case where there's no TTY
        match enable_raw_mode() {
            Ok(_) => Ok(Terminal { raw_mode: true }),
            Err(e) => {
                // If we can't enable raw mode (e.g., no TTY),
                // we can still work in non-raw mode for testing
                eprintln!(
                    "Warning: Could not enable raw mode: {}. Running in non-interactive mode.",
                    e
                );
                Ok(Terminal { raw_mode: false })
            }
        }
    }

    pub fn read_key(&self) -> io::Result<Option<KeyEvent>> {
        if !self.raw_mode {
            return Ok(None);
        }

        if event::poll(std::time::Duration::from_millis(10))? {
            if let Event::Key(key) = event::read()? {
                return Ok(Some(key));
            }
        }
        Ok(None)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        if self.raw_mode {
            let _ = disable_raw_mode();
        }
    }
}
