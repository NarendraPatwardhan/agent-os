//! Word fragments — the *unexpanded* pieces of a shell word.
//!
//! A shell word like `foo"$bar"baz` is not one string but a sequence of [`WordPart`]s
//! that concatenate left-to-right (here: a literal, a double-quoted variable, a
//! literal). Keeping the pieces distinct — rather than a flat string — is what lets
//! expansion (`expand.rs`) apply the POSIX rules correctly: whether a `$var` result is
//! subject to IFS word-splitting and pathname globbing depends on whether that
//! fragment sat inside quotes, so each fragment records its quoting.

use alloc::string::String;
use alloc::vec::Vec;

/// One fragment of a word.
///
/// The quoting flags are load-bearing, not cosmetic: they decide *post-expansion*
/// behaviour. A quoted fragment's expansion is never split on IFS and never globbed,
/// and a literal `*` that came from inside quotes is not a glob metacharacter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WordPart {
    /// Literal text (unquoted, single-quoted, or produced by an escape).
    /// `from_quote` marks text that came from inside quotes, so a literal `*` there
    /// is not treated as a glob metacharacter downstream.
    Lit { text: String, from_quote: bool },
    /// `$NAME`, `${NAME}`, or a `${NAME<op>word}` parameter expansion.
    Var {
        name: String,
        op: ParamOp,
        quoted: bool,
    },
    /// `$( … )` or `` ` … ` `` — the raw inner command text, run and spliced in.
    Sub { raw: String, quoted: bool },
    /// `$(( … ))` — the raw arithmetic expression text; evaluates to an integer.
    Arith { raw: String, quoted: bool },
}

impl WordPart {
    /// Convenience constructor for unquoted literal text.
    pub fn lit(text: impl Into<String>) -> Self {
        WordPart::Lit {
            text: text.into(),
            from_quote: false,
        }
    }
}

/// A word: parts that concatenate left-to-right.
pub type Word = Vec<WordPart>;

/// The operator carried by a `${NAME<op>word}` parameter expansion.
///
/// `colon` distinguishes the `:`-prefixed forms (which treat an *empty* value like an
/// unset one) from the bare forms (which act only when truly unset) — e.g. `${x:-d}`
/// vs `${x-d}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParamOp {
    /// `$NAME` / `${NAME}`
    Get,
    /// `${#NAME}` — string length.
    Length,
    /// `${NAME:-word}` / `${NAME-word}` — value if unset[/null].
    Default { colon: bool, word: Word },
    /// `${NAME:=word}` / `${NAME=word}` — assign default if unset[/null].
    Assign { colon: bool, word: Word },
    /// `${NAME:+word}` / `${NAME+word}` — alternative if set[/non-null].
    Alt { colon: bool, word: Word },
    /// `${NAME:?word}` / `${NAME?word}` — error if unset[/null].
    Error { colon: bool, word: Word },
    /// `${NAME#pat}` (shortest) / `${NAME##pat}` (longest) — trim a prefix.
    TrimPrefix { longest: bool, pat: Word },
    /// `${NAME%pat}` (shortest) / `${NAME%%pat}` (longest) — trim a suffix.
    TrimSuffix { longest: bool, pat: Word },
}
