//! Inter-process communication via pipes using ring buffers.
#![allow(dead_code)]

use alloc::boxed::Box;
use alloc::vec::Vec;
use core::cell::UnsafeCell;

pub const PIPE_BUFFER_SIZE: usize = 64 * 1024; // 64KB ring buffer

/// Ring buffer for pipe communication
pub struct RingBuffer {
    data: UnsafeCell<Vec<u8>>,
    read_pos: UnsafeCell<usize>,
    write_pos: UnsafeCell<usize>,
    size: usize,
}

impl RingBuffer {
    pub fn new() -> Self {
        let mut data = Vec::with_capacity(PIPE_BUFFER_SIZE);
        data.resize(PIPE_BUFFER_SIZE, 0);

        Self {
            data: UnsafeCell::new(data),
            read_pos: UnsafeCell::new(0),
            write_pos: UnsafeCell::new(0),
            size: PIPE_BUFFER_SIZE,
        }
    }

    /// Write data to the buffer. Returns number of bytes written.
    pub fn write(&self, buf: &[u8]) -> usize {
        unsafe {
            let data = &mut *self.data.get();
            let mut write_pos = *self.write_pos.get();
            let read_pos = *self.read_pos.get();

            let mut written = 0;

            for &byte in buf {
                // Check if buffer is full
                let next_write = (write_pos + 1) % self.size;
                if next_write == read_pos {
                    break; // Buffer full
                }

                data[write_pos] = byte;
                write_pos = next_write;
                written += 1;
            }

            *self.write_pos.get() = write_pos;
            written
        }
    }

    /// Read data from the buffer. Returns number of bytes read.
    pub fn read(&self, buf: &mut [u8]) -> usize {
        unsafe {
            let data = &*self.data.get();
            let mut current_pos = *self.read_pos.get();
            let write_pos = *self.write_pos.get();

            let mut read = 0;

            while read < buf.len() && current_pos != write_pos {
                buf[read] = data[current_pos];
                current_pos = (current_pos + 1) % self.size;
                read += 1;
            }

            *self.read_pos.get() = current_pos;
            read
        }
    }

    /// Check if buffer is empty
    pub fn is_empty(&self) -> bool {
        unsafe { *self.read_pos.get() == *self.write_pos.get() }
    }

    /// Check if buffer is full
    pub fn is_full(&self) -> bool {
        unsafe {
            let next_write = (*self.write_pos.get() + 1) % self.size;
            next_write == *self.read_pos.get()
        }
    }

    /// Get available space for writing
    pub fn available_space(&self) -> usize {
        unsafe {
            let read_pos = *self.read_pos.get();
            let write_pos = *self.write_pos.get();

            if write_pos >= read_pos {
                self.size - (write_pos - read_pos) - 1
            } else {
                read_pos - write_pos - 1
            }
        }
    }

    /// Get available data for reading
    pub fn available_data(&self) -> usize {
        unsafe {
            let read_pos = *self.read_pos.get();
            let write_pos = *self.write_pos.get();

            if write_pos >= read_pos {
                write_pos - read_pos
            } else {
                self.size - read_pos + write_pos
            }
        }
    }
}

unsafe impl Sync for RingBuffer {}

/// Pipe endpoints for IPC.
///
/// The read and write ends are **reference counted** (`readers`/`writers`),
/// not simple booleans: a pipe end may be held by several fds at once (e.g. the
/// shell holds a write end *and* hands a duplicate to a spawned child via
/// `spawn`). The end is only "closed" — and the peer only sees EOF / broken
/// pipe — when the last holder releases it. This is required for real pipelines
/// where an intermediate stage runs as a separate process.
pub struct Pipe {
    pub buffer: Box<RingBuffer>,
    pub blocked_reader: UnsafeCell<Option<u32>>, // TaskId waiting to read
    pub blocked_writer: UnsafeCell<Option<u32>>, // TaskId waiting to write
    readers: UnsafeCell<usize>,
    writers: UnsafeCell<usize>,
}

impl Pipe {
    pub fn new() -> Self {
        Self {
            buffer: Box::new(RingBuffer::new()),
            blocked_reader: UnsafeCell::new(None),
            blocked_writer: UnsafeCell::new(None),
            readers: UnsafeCell::new(0),
            writers: UnsafeCell::new(0),
        }
    }

    /// Acquire a reference to the read / write end (called when a `PipeSource` /
    /// `PipeSink` is created).
    pub fn add_reader(&self) {
        unsafe {
            *self.readers.get() += 1;
        }
    }
    pub fn add_writer(&self) {
        unsafe {
            *self.writers.get() += 1;
        }
    }

    /// Release one reference to the read end of the pipe.
    pub fn close_read(&self) {
        unsafe {
            let r = self.readers.get();
            *r = (*r).saturating_sub(1);
        }
    }

    /// Release one reference to the write end of the pipe.
    pub fn close_write(&self) {
        unsafe {
            let w = self.writers.get();
            *w = (*w).saturating_sub(1);
        }
    }

    /// True once every holder of the read end has released it.
    pub fn is_read_closed(&self) -> bool {
        unsafe { *self.readers.get() == 0 }
    }

    /// True once every holder of the write end has released it.
    pub fn is_write_closed(&self) -> bool {
        unsafe { *self.writers.get() == 0 }
    }

    /// Block a reader task
    pub fn block_reader(&self, task_id: u32) {
        unsafe {
            *self.blocked_reader.get() = Some(task_id);
        }
    }

    /// Block a writer task
    pub fn block_writer(&self, task_id: u32) {
        unsafe {
            *self.blocked_writer.get() = Some(task_id);
        }
    }

    /// Unblock reader and return the task id
    pub fn unblock_reader(&self) -> Option<u32> {
        unsafe {
            let task_id = *self.blocked_reader.get();
            *self.blocked_reader.get() = None;
            task_id
        }
    }

    /// Unblock writer and return the task id
    pub fn unblock_writer(&self) -> Option<u32> {
        unsafe {
            let task_id = *self.blocked_writer.get();
            *self.blocked_writer.get() = None;
            task_id
        }
    }
}

unsafe impl Sync for Pipe {}
