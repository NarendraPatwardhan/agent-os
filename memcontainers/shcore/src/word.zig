//! Unexpanded shell word fragments.

pub const Word = []const WordPart;

pub const WordPart = union(enum) {
    lit: Lit,
    param: Var,
    sub: Sub,
    arith: Arith,

    pub fn literal(text: []const u8) WordPart {
        return .{ .lit = .{ .text = text, .from_quote = false } };
    }
};

pub const Lit = struct {
    text: []const u8,
    from_quote: bool,
};

pub const Var = struct {
    name: []const u8,
    op: ParamOp = .get,
    quoted: bool,
};

pub const Sub = struct {
    raw: []const u8,
    quoted: bool,
};

pub const Arith = struct {
    raw: []const u8,
    quoted: bool,
};

pub const ParamOp = union(enum) {
    get,
    length,
    default_value: ParamWord,
    assign: ParamWord,
    alt: ParamWord,
    err: ParamWord,
    trim_prefix: TrimWord,
    trim_suffix: TrimWord,
};

pub const ParamWord = struct {
    colon: bool,
    word: Word,
};

pub const TrimWord = struct {
    longest: bool,
    pat: Word,
};
