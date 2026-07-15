// analyze_main.cpp — `/bin/luau-analyze` (L4): the Luau type checker.
// Parse + typecheck a file AND the module graph it `require()`s, printing
// `file:line:col: message` for each diagnostic across every module; exit non-zero
// if any. `luau --check f.luau` execs this. Diagnostics go to stdout (like `tsc`).
//
// Built from the vendored Luau.Analysis (the real type-inference engine), ported to
// the wasm guest via analysis_eh_shim.h (force-included, -fno-exceptions): Luau
// type errors are DATA (CheckResult.errors), so ordinary checking is unaffected;
// only internal/resource-limit conditions (which throw) degrade to a graceful abort.

#include "Luau/Ast.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Config.h"
#include "Luau/ConfigResolver.h"
#include "Luau/Error.h"
#include "Luau/FileResolver.h"
#include "Luau/Frontend.h"
#include "Luau/ParseOptions.h"
#include "Luau/TypeArena.h"

#include <optional>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

// Declared by analysis_eh_shim.h (force-included into the Analysis TUs), defined
// here: the graceful, noreturn exit the patched throw sites call.
extern "C" __attribute__((noreturn)) void mc_analysis_abort(const char *what) {
    fputs(what, stderr);
    fputc('\n', stderr);
    exit(70);
}

// File IO over the mc syscalls DIRECTLY (not stdio: fread's two-iovec readv into the FILE buffer
// faults under the wasi→mc adapter). mc_sys_close is a real syscall, so the fd is properly closed —
// and file_exists stats instead of opening, so require resolution can't leak fds across a big
// graph.
extern "C" {
__attribute__((import_module("mc"), import_name("mc_sys_open"))) int mc_sys_open(unsigned, unsigned,
                                                                                 int, unsigned);
__attribute__((import_module("mc"), import_name("mc_sys_read"))) int
mc_sys_read(int, unsigned, unsigned, unsigned);
__attribute__((import_module("mc"), import_name("mc_sys_close"))) int mc_sys_close(int);
__attribute__((import_module("mc"), import_name("mc_sys_lstat"))) int
mc_sys_lstat(unsigned, unsigned, unsigned);
}
static inline unsigned a32(const void *p) { return (unsigned)(size_t)p; }

static std::optional<std::string> read_file(const char *path) {
    unsigned fd = 0;
    if (mc_sys_open(a32(path), (unsigned)strlen(path), 1 /*O_READ*/, a32(&fd)) != 0)
        return std::nullopt;
    std::string s;
    char buf[8192];
    unsigned n = 0;
    while (mc_sys_read((int)fd, a32(buf), sizeof(buf), a32(&n)) == 0 && n > 0)
        s.append(buf, n);
    mc_sys_close((int)fd);
    return s;
}

static bool file_exists(const std::string &p) {
    unsigned char st[44];
    return mc_sys_lstat(a32(p.c_str()), (unsigned)p.size(), a32(st)) == 0;
}

static std::string dir_of(const std::string &p) {
    size_t s = p.find_last_of('/');
    return s == std::string::npos ? std::string() : p.substr(0, s);
}

// Lexically resolve `.`/`..`, collapse `//`, keep a leading `/`.
static std::string normalize_path(const std::string &p) {
    bool abs = !p.empty() && p[0] == '/';
    std::vector<std::string> parts;
    size_t i = 0;
    while (i < p.size()) {
        size_t j = p.find('/', i);
        if (j == std::string::npos)
            j = p.size();
        std::string seg = p.substr(i, j - i);
        if (seg.empty() || seg == ".") {
            // skip
        } else if (seg == "..") {
            if (!parts.empty() && parts.back() != "..")
                parts.pop_back();
            else if (!abs)
                parts.push_back("..");
        } else {
            parts.push_back(seg);
        }
        i = j + 1;
    }
    std::string out;
    for (size_t k = 0; k < parts.size(); k++) {
        if (k)
            out += "/";
        out += parts[k];
    }
    if (abs)
        out = "/" + out;
    return out.empty() ? (abs ? std::string("/") : std::string(".")) : out;
}

static bool exceeds_nesting_limit(const std::string &src, unsigned limit) {
    enum class State { Code, LineComment, BlockComment, SingleQuote, DoubleQuote };

    State state = State::Code;
    unsigned depth = 0;
    for (size_t i = 0; i < src.size(); i++) {
        char c = src[i];
        char n = i + 1 < src.size() ? src[i + 1] : '\0';

        switch (state) {
        case State::LineComment:
            if (c == '\n')
                state = State::Code;
            break;
        case State::BlockComment:
            if (c == ']' && n == ']') {
                i++;
                state = State::Code;
            }
            break;
        case State::SingleQuote:
            if (c == '\\' && n != '\0')
                i++;
            else if (c == '\'')
                state = State::Code;
            break;
        case State::DoubleQuote:
            if (c == '\\' && n != '\0')
                i++;
            else if (c == '"')
                state = State::Code;
            break;
        case State::Code:
            if (c == '-' && n == '-') {
                if (i + 3 < src.size() && src[i + 2] == '[' && src[i + 3] == '[') {
                    i += 3;
                    state = State::BlockComment;
                } else {
                    i++;
                    state = State::LineComment;
                }
            } else if (c == '\'') {
                state = State::SingleQuote;
            } else if (c == '"') {
                state = State::DoubleQuote;
            } else if (c == '{') {
                if (++depth > limit)
                    return true;
            } else if (c == '}' && depth != 0) {
                depth--;
            }
            break;
        }
    }

    return false;
}

// Resolve a `require(<req>)` string (relative to the requiring file `base`) to an
// on-disk module path, trying `<p>`, `<p>.luau`, `<p>.lua`, `<p>/init.luau`. Empty
// if unresolved (the Frontend then reports it like any unresolved import).
static std::string resolve_require(const std::string &base, const std::string &req) {
    std::string joined = (!req.empty() && req[0] == '/') ? req : (dir_of(base) + "/" + req);
    joined = normalize_path(joined);
    const std::string candidates[] = {joined, joined + ".luau", joined + ".lua",
                                      joined + "/init.luau"};
    for (const std::string &c : candidates)
        if (file_exists(c))
            return c;
    return std::string();
}

namespace {

// Serves any file by path (the module NAME is its path), and resolves `require()`
// across the graph — so the whole project is type-checked, not just the entry file.
struct DiskFileResolver : Luau::FileResolver {
    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName &name) override {
        std::optional<std::string> s = read_file(name.c_str());
        if (!s)
            return std::nullopt;
        return Luau::SourceCode{*s, Luau::SourceCode::Module};
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo *context,
                                                  Luau::AstExpr *node,
                                                  const Luau::TypeCheckLimits &) override {
        if (Luau::AstExprConstantString *expr = node->as<Luau::AstExprConstantString>()) {
            std::string req{expr->value.data, expr->value.size};
            std::string base = context ? context->name : std::string();
            std::string resolved = resolve_require(base, req);
            if (!resolved.empty())
                return Luau::ModuleInfo{resolved};
        }
        return std::nullopt;
    }
};

// One fixed config (the entry file's --! mode is the project default; each module's
// own --! comment still overrides it, which the parser handles per-module).
struct DefaultConfigResolver : Luau::ConfigResolver {
    Luau::Config config;
    explicit DefaultConfigResolver(Luau::Mode mode) { config.mode = mode; }

    const Luau::Config &getConfig(const Luau::ModuleName &,
                                  const Luau::TypeCheckLimits &) const override {
        return config;
    }
};

} // namespace

// The entry, called by analyze_entry.zig's __main_argc_argv (a thin Zig forwarder owns the wasi
// _start path, as for /bin/luau). Renamed from `main` so the Zig root, not this C++ TU, defines the
// wasi entry.
extern "C" int mc_analyze_run(int argc, char **argv) {
    // Diagnostics go to stdout (like `tsc`): they're this tool's product, and a
    // spawned guest's stdout is what the parent/`luau --check` captures. Line-buffer
    // so each diagnostic flushes promptly (cf. luau_cli.cpp).
    setvbuf(stdout, nullptr, _IOLBF, 4096);

    if (argc >= 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        fputs("luau-analyze — type-check a Luau file and report diagnostics\n"
              "\n"
              "Usage: luau-analyze FILE.luau\n"
              "\n"
              "Type-checks FILE and every module it `require`s, printing\n"
              "`file:line:col: message` diagnostics to stdout (like tsc). The inference\n"
              "mode comes from the entry file's header: --!strict (the default),\n"
              "--!nonstrict, or --!nocheck. This is the engine behind `luau --check`.\n"
              "\n"
              "Options:\n"
              "  -h, --help  display this help and exit\n"
              "\n"
              "Exit status:\n"
              "  0  no errors were found\n"
              "  1  type or lint errors were reported\n"
              "  2  a usage error, or the file could not be opened\n",
              stdout);
        return 0;
    }

    if (argc < 2) {
        fputs("usage: luau-analyze <file.luau>\n", stderr);
        return 2;
    }
    const char *path = argv[1];
    std::optional<std::string> src = read_file(path);
    if (!src) {
        fprintf(stderr, "luau-analyze: cannot open %s\n", path);
        return 2;
    }
    if (exceeds_nesting_limit(*src, 1024)) {
        fprintf(stdout, "%s:1:1: program: call stack exhausted\n", path);
        fprintf(stdout, "luau-analyze: 1 error\n");
        return 1;
    }

    // Project-default inference mode from the entry file's --! header (default
    // strict, the most useful for an agent authoring typed Luau).
    Luau::Mode mode = Luau::Mode::Strict;
    if (src->find("--!nocheck") != std::string::npos)
        mode = Luau::Mode::NoCheck;
    else if (src->find("--!nonstrict") != std::string::npos)
        mode = Luau::Mode::Nonstrict;

    DiskFileResolver fileResolver;
    DefaultConfigResolver configResolver(mode);

    Luau::FrontendOptions options;
    options.runLintChecks = false;
    Luau::Frontend frontend(Luau::SolverMode::New, &fileResolver, &configResolver, options);

    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    Luau::freeze(frontend.globals.globalTypes);

    // Check the entry module; the Frontend recurses through resolveModule/readSource
    // into every required module. accumulateNested=true gathers the WHOLE graph's
    // errors, each tagged with its own moduleName.
    frontend.check(path);
    std::optional<Luau::CheckResult> cr = frontend.getCheckResult(path, /*accumulateNested=*/true);

    int count = 0;
    if (cr) {
        for (const Luau::TypeError &e : cr->errors) {
            std::string msg =
                Luau::toString(e, Luau::TypeErrorToStringOptions{frontend.fileResolver});
            const char *mod = e.moduleName.empty() ? path : e.moduleName.c_str();
            // Luau Position is 0-based; humans count from 1.
            fprintf(stdout, "%s:%u:%u: %s\n", mod, e.location.begin.line + 1u,
                    e.location.begin.column + 1u, msg.c_str());
            count++;
        }
    }
    if (count > 0)
        fprintf(stdout, "luau-analyze: %d error%s\n", count, count == 1 ? "" : "s");
    return count > 0 ? 1 : 0;
}
