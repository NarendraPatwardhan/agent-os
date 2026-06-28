//! The in-kernel **rescue shell**: a minimal flat-splitter shell used only when
//! `/bin/sh` is unavailable (a no-image boot, or the `mc_ctl_exec` fallback).
//! The full POSIX-ish shell — expansions, command substitution, control flow,
//! functions, job control — lives in the `shcore` crate and runs as the
//! guest `/bin/sh` (which is also pid 1). So there is deliberately no lexer/
//! expander here: `parser::parse_line` splits a line into pipelines joined by
//! `; && || &` with redirects, and `pipeline` runs them.
pub mod executor;
pub mod parser;
pub mod pipeline;

pub use executor::Executor;
pub use parser::{parse_line, Pipeline, PipelineSeq, Sep};
pub use pipeline::{
    reap_finished, run_round, submit_pipeline, submit_pipeline_captured, OutputCapture,
};
