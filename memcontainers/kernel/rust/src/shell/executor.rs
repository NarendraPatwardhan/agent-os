//! Builtin registry.
//!
//! A builtin is identified by name and produced via a factory:
//! `fn(args: Vec<String>) -> Box<dyn Builtin>`. The pipeline runner asks
//! the executor for a factory and instantiates one program per task at
//! submit time; the program owns its own state for the lifetime of the
//! task.

use alloc::collections::BTreeMap;
use alloc::string::String;

use crate::builtins::BuiltinFactory;

pub struct Executor {
    pub factories: BTreeMap<String, BuiltinFactory>,
}

impl Executor {
    pub fn new() -> Self {
        Self {
            factories: BTreeMap::new(),
        }
    }

    pub fn register(&mut self, name: &str, factory: BuiltinFactory) {
        self.factories.insert(String::from(name), factory);
    }

    pub fn lookup(&self, name: &str) -> Option<BuiltinFactory> {
        self.factories.get(name).copied()
    }
}
