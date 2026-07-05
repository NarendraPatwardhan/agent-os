//! Structured, agent-oriented `--help` (DESIGN.md §6.2). One `Help` value per applet is
//! rendered by the single formatter here, so all applets share a byte-for-byte identical,
//! machine-parseable layout: fixed uppercase section headers in a fixed order, empty
//! sections omitted. The distinguishing section for LLM/agent consumers is DEVIATIONS --
//! how this applet differs from its parity oracle (GNU coreutils / GNU sed / jq), since an
//! agent's prior is standard behavior.
//!
//! OPTIONS is data-driven: declarative applets let `core/cli.zig` derive the option lines
//! from their `cli.Spec` (no double-maintenance); hand-parsed applets pass an explicit
//! `options` list. This file imports NOTHING from `cli.zig` (cli imports it) to keep the
//! dependency acyclic -- the caller hands `render` a ready-made `[]const Opt`.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;

const WIDTH: usize = 78; // wrap column for prose/deviation/option text
const OPT_COL_MAX: usize = 22; // cap on the OPTIONS left-column width

pub const Exit = struct { code: u8, when: []const u8 };
pub const Example = struct { cmd: []const u8, note: []const u8 = "" };

/// One OPTIONS row. `flags` is the pre-formatted left column (e.g. `-n, --lines=N`); for
/// declarative applets cli.zig builds these from the spec.
pub const Opt = struct { flags: []const u8, desc: []const u8 };

pub const Help = struct {
    /// Right-hand side of NAME: `<applet> — <summary>`. One line, lowercase, no period.
    summary: []const u8,
    /// One or more real usage forms.
    synopsis: []const []const u8,
    /// Prose; may contain `\n` to separate paragraphs. Rendered indented + wrapped.
    description: []const u8,
    /// A sentence used INSTEAD of an OPTIONS list (e.g. "printf takes no options.").
    options_note: []const u8 = "",
    /// Explicit OPTIONS rows (hand-parsed applets). Declarative applets leave this empty
    /// and cli.zig supplies the rows from the spec.
    options: []const Opt = &.{},
    /// OPERANDS prose (positional args, the `-`=stdin convention, defaults).
    operands: []const u8 = "",
    /// EXIT STATUS table.
    exit: []const Exit = &.{},
    /// DEVIATIONS bullets; each is one deviation from `deviations_from`.
    deviations: []const []const u8 = &.{},
    deviations_from: []const u8 = "GNU coreutils",
    /// 1-3 worked examples.
    examples: []const Example = &.{},
    /// SEE ALSO prose (related applets), where it aids tool-selection.
    see_also: []const u8 = "",
};

const Buf = std.ArrayListUnmanaged(u8);

fn put(b: *Buf, gpa: std.mem.Allocator, s: []const u8) void {
    b.appendSlice(gpa, s) catch {};
}

fn spaces(b: *Buf, gpa: std.mem.Allocator, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) b.append(gpa, ' ') catch {};
}

/// Flow-wraps `text` into `b` at `WIDTH`. Prose authored as a `\\` multiline literal flows
/// naturally: a single newline is treated as a space (so source lines re-flow), and a
/// blank line separates paragraphs (rendered as a blank line). Every line is indented by
/// `first`/`cont` (both `indent` here since prose has no hanging indent). A word longer
/// than the remaining width is placed anyway (never split).
fn wrap(b: *Buf, gpa: std.mem.Allocator, text: []const u8, first: usize, cont: usize) void {
    _ = cont;
    var paras = std.mem.splitSequence(u8, text, "\n\n");
    var para_no: usize = 0;
    while (paras.next()) |para| {
        if (para_no != 0) put(b, gpa, "\n"); // blank line between paragraphs
        para_no += 1;
        var col: usize = first;
        spaces(b, gpa, first);
        var at_start = true;
        var words = std.mem.tokenizeAny(u8, para, " \t\n"); // \n as whitespace -> flow
        while (words.next()) |w| {
            if (!at_start and col + 1 + w.len > WIDTH) {
                put(b, gpa, "\n");
                spaces(b, gpa, first);
                col = first;
                at_start = true;
            }
            if (!at_start) {
                put(b, gpa, " ");
                col += 1;
            }
            put(b, gpa, w);
            col += w.len;
            at_start = false;
        }
        put(b, gpa, "\n");
    }
}

fn header(b: *Buf, gpa: std.mem.Allocator, name: []const u8) void {
    put(b, gpa, name);
    put(b, gpa, "\n");
}

/// Renders `h` for applet `name` into `ctx.stdout`. `options` is the OPTIONS rows to show
/// (cli.zig passes spec-derived rows for declarative applets; hand-parsed applets pass
/// `h.options`).
pub fn render(ctx: *Ctx, name: []const u8, h: Help, options: []const Opt) void {
    const gpa = ctx.gpa;
    var b: Buf = .empty;

    // NAME
    header(&b, gpa, "NAME");
    spaces(&b, gpa, 4);
    put(&b, gpa, name);
    put(&b, gpa, " \u{2014} "); // em dash
    put(&b, gpa, h.summary);
    put(&b, gpa, "\n\n");

    // SYNOPSIS
    header(&b, gpa, "SYNOPSIS");
    for (h.synopsis) |form| {
        spaces(&b, gpa, 4);
        put(&b, gpa, form);
        put(&b, gpa, "\n");
    }
    put(&b, gpa, "\n");

    // DESCRIPTION
    header(&b, gpa, "DESCRIPTION");
    wrap(&b, gpa, h.description, 4, 4);

    // OPTIONS
    if (options.len != 0 or h.options_note.len != 0) {
        put(&b, gpa, "\n");
        header(&b, gpa, "OPTIONS");
        if (h.options_note.len != 0) {
            wrap(&b, gpa, h.options_note, 4, 4);
        }
        // left-column width = max flags length (capped), +2 gutter
        var flagw: usize = 0;
        for (options) |o| flagw = @max(flagw, o.flags.len);
        flagw = @min(flagw, OPT_COL_MAX);
        for (options) |o| {
            spaces(&b, gpa, 4);
            put(&b, gpa, o.flags);
            if (o.flags.len > flagw) {
                // flags overflow the column: description on the next line
                put(&b, gpa, "\n");
                wrap(&b, gpa, o.desc, 4 + flagw + 2, 4 + flagw + 2);
            } else {
                spaces(&b, gpa, flagw - o.flags.len + 2);
                // first line already indented via the flags; wrap continuations to column
                wrapInline(&b, gpa, o.desc, 4 + flagw + 2);
            }
        }
    }

    // OPERANDS
    if (h.operands.len != 0) {
        put(&b, gpa, "\n");
        header(&b, gpa, "OPERANDS");
        wrap(&b, gpa, h.operands, 4, 4);
    }

    // EXIT STATUS
    if (h.exit.len != 0) {
        put(&b, gpa, "\n");
        header(&b, gpa, "EXIT STATUS");
        for (h.exit) |e| {
            spaces(&b, gpa, 4);
            var nb: [4]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{e.code}) catch "?";
            put(&b, gpa, ns);
            spaces(&b, gpa, 5 - ns.len);
            wrapInline(&b, gpa, e.when, 4 + 5);
        }
    }

    // DEVIATIONS
    if (h.deviations.len != 0) {
        put(&b, gpa, "\n");
        put(&b, gpa, "DEVIATIONS (from ");
        put(&b, gpa, h.deviations_from);
        put(&b, gpa, ")\n");
        for (h.deviations) |d| {
            spaces(&b, gpa, 4);
            put(&b, gpa, "- ");
            wrapInline(&b, gpa, d, 6);
        }
    }

    // EXAMPLES
    if (h.examples.len != 0) {
        put(&b, gpa, "\n");
        header(&b, gpa, "EXAMPLES");
        for (h.examples) |ex| {
            spaces(&b, gpa, 4);
            put(&b, gpa, ex.cmd);
            if (ex.note.len != 0) {
                put(&b, gpa, "  # ");
                put(&b, gpa, ex.note);
            }
            put(&b, gpa, "\n");
        }
    }

    // SEE ALSO
    if (h.see_also.len != 0) {
        put(&b, gpa, "\n");
        header(&b, gpa, "SEE ALSO");
        wrap(&b, gpa, h.see_also, 4, 4);
    }

    ctx.outWrite(b.items) catch {};
}

/// Wrap helper for text whose FIRST line's indent was already emitted by the caller (the
/// cursor is at column `col`). Continuation lines indent to `col`.
fn wrapInline(b: *Buf, gpa: std.mem.Allocator, text: []const u8, col: usize) void {
    var cur = col;
    var at_start = true;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    while (words.next()) |w| {
        if (!at_start and cur + 1 + w.len > WIDTH) {
            put(b, gpa, "\n");
            spaces(b, gpa, col);
            cur = col;
            at_start = true;
        }
        if (!at_start) {
            put(b, gpa, " ");
            cur += 1;
        }
        put(b, gpa, w);
        cur += w.len;
        at_start = false;
    }
    put(b, gpa, "\n");
}
