-- calc.luau — a pure-Luau Excel formula engine (SYSTEMS.md §10.3 / luau-extensions
-- design Ch.12). Tokenize → parse (precedence-climbing) → evaluate against a
-- host-provided cell/range resolver, with a dependency extractor for whole-workbook
-- recalculation. Ported from fast-formula-parser (MIT, grammar/operators/error model)
-- and formulajs (MIT, function semantics); validated against the Python `formulas`
-- engine. No backend — pure computation; the host (xlsx) supplies the cell grid and
-- (optionally) an injected clock/RNG for volatile functions.
--
-- The engine is decoupled from xlsx storage: it works with its own internal Value
-- model and asks for cells/ranges through `ctx`, so the same engine could drive any
-- grid. Scalars are raw Luau values (number/string/boolean); errors, blanks, arrays
-- and references are tagged tables.

local calc = {}

-- ===========================================================================
-- Error values (the 7 Excel errors + #ERROR! for parse failures). Singletons.
-- ===========================================================================

local ERR = {}
local function mkerr(code)
	local e = { __err = true, code = code }
	ERR[code] = e
	return e
end
ERR.DIV0 = mkerr("#DIV/0!")
ERR.NA = mkerr("#N/A")
ERR.NAME = mkerr("#NAME?")
ERR.NULL = mkerr("#NULL!")
ERR.NUM = mkerr("#NUM!")
ERR.REF = mkerr("#REF!")
ERR.VALUE = mkerr("#VALUE!")
ERR.ERROR = mkerr("#ERROR!") -- parse/lex failures (Excel surfaces these as #NAME?/#ERROR!)
calc.ERR = ERR

local function is_error(v)
	return type(v) == "table" and v.__err == true
end
local function error_for(code)
	return ERR[code] or { __err = true, code = code }
end
calc.isError = is_error
calc.errorCode = function(v)
	return is_error(v) and v.code or nil
end

-- BLANK — an empty cell / omitted argument. A singleton (distinct from "" and 0).
local BLANK = { __blank = true }
local function is_blank(v)
	return v == BLANK
end

-- An array value (2-D): { __arr=true, data={{…},…}, rows, cols }. A reference value:
-- a cell { __ref="cell", sheet?, col, row } or a range { __ref="range", sheet?, c1,
-- r1, c2, r2 } — references carry their address so reference-aware functions (SUM,
-- OFFSET, …) can resolve ranges instead of pre-fetched values.
local function is_array(v)
	return type(v) == "table" and v.__arr == true
end
local function is_ref(v)
	return type(v) == "table" and v.__ref ~= nil
end
local function mkarray(data)
	return { __arr = true, data = data, rows = #data, cols = (data[1] and #data[1]) or 0 }
end
calc.isArray = is_array

local MAXROW, MAXCOL = 1048576, 16384

-- ===========================================================================
-- A1 addressing (column letters ↔ number)
-- ===========================================================================

local function col_to_num(letters)
	local n = 0
	for i = 1, #letters do
		n = n * 26 + (string.byte(letters, i) - 64) -- 'A' = 65 → 1
	end
	return n
end

local function num_to_col(n)
	local s = ""
	while n > 0 do
		local r = (n - 1) % 26
		s = string.char(65 + r) .. s
		n = (n - 1) // 26
	end
	return s
end
calc.colToNum = col_to_num
calc.numToCol = num_to_col

-- An Address {col,row} → an A1 string (no $).
local function addr_to_a1(col, row)
	return num_to_col(col) .. tostring(row)
end
calc.addrToA1 = addr_to_a1

-- ===========================================================================
-- Value coercion (Excel semantics; ported from helpers.js acceptNumber + operators)
-- ===========================================================================

-- A number → its Excel "General" text (15 significant digits, trailing zeros
-- trimmed; integers print without a decimal point).
local function num_to_str(n)
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%.0f", n)
	end
	return string.format("%.15g", n)
end

-- Coerce a scalar Value → number, or an error Value. Booleans → 1/0; blank → 0;
-- numeric strings → their number ("" and non-numeric → #VALUE!).
local function to_number(v)
	if is_error(v) then
		return v
	end
	local t = type(v)
	if t == "number" then
		return v
	end
	if t == "boolean" then
		return v and 1 or 0
	end
	if is_blank(v) then
		return 0
	end
	if t == "string" then
		if v == "" then
			return ERR.VALUE
		end
		local n = tonumber(v)
		if n == nil then
			return ERR.VALUE
		end
		return n
	end
	return ERR.VALUE
end

-- Coerce a scalar Value → string (errors propagate via the caller; blank → "").
local function to_string(v)
	if is_error(v) then
		return v
	end
	local t = type(v)
	if t == "string" then
		return v
	end
	if t == "number" then
		return num_to_str(v)
	end
	if t == "boolean" then
		return v and "TRUE" or "FALSE"
	end
	if is_blank(v) then
		return ""
	end
	return ""
end

-- Coerce a scalar Value → boolean, or an error. Numbers → n~=0; "TRUE"/"FALSE"
-- (case-insensitive) → bool; blank → false; other strings → #VALUE!.
local function to_boolean(v)
	if is_error(v) then
		return v
	end
	local t = type(v)
	if t == "boolean" then
		return v
	end
	if t == "number" then
		return v ~= 0
	end
	if is_blank(v) then
		return false
	end
	if t == "string" then
		local u = v:upper()
		if u == "TRUE" then
			return true
		end
		if u == "FALSE" then
			return false
		end
		return ERR.VALUE
	end
	return ERR.VALUE
end

calc.BLANK = BLANK

-- ===========================================================================
-- Lexer
-- ===========================================================================

local ERROR_LITERALS = {
	"#DIV/0!",
	"#N/A",
	"#NAME?",
	"#NULL!",
	"#NUM!",
	"#REF!",
	"#VALUE!",
	"#GETTING_DATA",
	"#SPILL!",
	"#CALC!",
}

-- Parse a "$?LETTERS$?DIGITS" cell body at src[i..] → (col,row,absCol,absRow,len) or
-- nil. Validates the column ≤ XFD and row ≤ 1048576.
local function match_cell(src, i)
	local absCol = false
	local j = i
	if src:sub(j, j) == "$" then
		absCol = true
		j += 1
	end
	local letters = src:match("^(%a+)", j)
	if not letters then
		return nil
	end
	j += #letters
	local absRow = false
	if src:sub(j, j) == "$" then
		absRow = true
		j += 1
	end
	local digits = src:match("^(%d+)", j)
	if not digits then
		return nil
	end
	local col, row = col_to_num(letters:upper()), tonumber(digits)
	if col > MAXCOL or row > MAXROW then
		return nil
	end
	return col, row, absCol, absRow, (j + #digits - i)
end

-- A reference token (optional sheet prefix + cell / cell:cell / col:col), starting at
-- src[i]. Returns (refTable, len) or nil. Row-ranges (1:1) are produced by the number
-- scanner. `funcAhead` is set when a bare cell is immediately followed by "(" (then
-- it is a function name, not a reference).
local function scan_reference(src, i)
	local j = i
	local sheet
	-- sheet prefix: 'quoted name'! or unquoted! (letters/digits/_/.). Lua patterns
	-- lack alternation, so the quoted form is scanned by hand (with '' un-escaping).
	if src:sub(j, j) == "'" then
		local k = j + 1
		local buf = {}
		while k <= #src do
			local c = src:sub(k, k)
			if c == "'" then
				if src:sub(k + 1, k + 1) == "'" then
					buf[#buf + 1] = "'"
					k += 2
				else
					break
				end
			else
				buf[#buf + 1] = c
				k += 1
			end
		end
		if src:sub(k, k) == "'" and src:sub(k + 1, k + 1) == "!" then
			sheet = table.concat(buf)
			j = k + 2
		else
			return nil -- malformed quoted prefix
		end
	else
		local name = src:match("^([%a_][%w_.]*)!", j)
		if name then
			-- a sheet prefix only if what follows is a reference (else it's e.g. a
			-- structured-table ref we don't model) — require a cell/col after "!"
			local after = j + #name + 1
			if match_cell(src, after) or src:match("^%$?%a+:", after) then
				sheet = name
				j = after
			end
		end
	end
	-- col:col range ($A:$C) — try before single cell so "A:A" isn't read as name
	do
		local a1, a2 = src:match("^%$?(%a+):%$?(%a+)", j)
		if a1 and a2 and not src:match("^%$?%a+%d", j) then
			local c1, c2 = col_to_num(a1:upper()), col_to_num(a2:upper())
			if c1 <= MAXCOL and c2 <= MAXCOL then
				local matched = src:match("^(%$?%a+:%$?%a+)", j)
				return {
					__ref = "range",
					sheet = sheet,
					c1 = math.min(c1, c2),
					r1 = 1,
					c2 = math.max(c1, c2),
					r2 = MAXROW,
					fullCol = true,
				},
					(j + #matched - i)
			end
		end
	end
	-- cell or cell:cell. A "reference" whose next char continues an identifier or is
	-- "(" is NOT a reference — it is a longer name / function (e.g. DEC2BIN parses
	-- as cell "DEC2" + "BIN", LOG10( as a function). `[%w_.(]` rejects both.
	local col, row, absCol, absRow, clen = match_cell(src, j)
	if not col then
		return nil
	end
	local afterCell = j + clen
	if src:sub(afterCell, afterCell) == ":" then
		local c2, r2, _, _, clen2 = match_cell(src, afterCell + 1)
		if c2 then
			local afterRange = afterCell + 1 + clen2
			if src:sub(afterRange, afterRange):match("[%w_.(]") then
				return nil
			end
			return {
				__ref = "range",
				sheet = sheet,
				c1 = math.min(col, c2),
				r1 = math.min(row, r2),
				c2 = math.max(col, c2),
				r2 = math.max(row, r2),
			},
				(afterRange - i)
		end
	end
	if src:sub(afterCell, afterCell):match("[%w_.(]") then
		return nil
	end
	return { __ref = "cell", sheet = sheet, col = col, row = row, absCol = absCol, absRow = absRow },
		(afterCell - i)
end

-- tokenize(src) → array of tokens { t=<type>, v=<value> }. Types: "num", "str",
-- "bool", "err", "ref", "name", "op", "(", ")", ",". Raises (returns) an #ERROR!
-- token on a malformed string. Whitespace is insignificant (intersection deferred).
local function tokenize(src)
	local toks = {}
	local i, n = 1, #src
	-- a leading "=" / "+" (some hosts pass "=A1") is stripped at the source boundary
	while i <= n do
		local c = src:sub(i, i)
		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			i += 1
		elseif c == '"' then
			-- string literal with "" escape
			local buf, j = {}, i + 1
			local closed = false
			while j <= n do
				local d = src:sub(j, j)
				if d == '"' then
					if src:sub(j + 1, j + 1) == '"' then
						buf[#buf + 1] = '"'
						j += 2
					else
						closed = true
						j += 1
						break
					end
				else
					buf[#buf + 1] = d
					j += 1
				end
			end
			if not closed then
				return nil, ERR.ERROR
			end
			toks[#toks + 1] = { t = "str", v = table.concat(buf) }
			i = j
		elseif c == "#" then
			local matched
			for _, lit in ipairs(ERROR_LITERALS) do
				if src:sub(i, i + #lit - 1) == lit then
					matched = lit
					break
				end
			end
			if not matched then
				return nil, ERR.ERROR
			end
			toks[#toks + 1] = { t = "err", v = error_for(matched) }
			i += #matched
		elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
			-- number; a number followed by ":" + number is a full-row range
			local num = src:match("^%d+%.?%d*[eE][%+%-]?%d+", i)
				or src:match("^%d*%.%d+[eE][%+%-]?%d+", i)
				or src:match("^%d+%.?%d*", i)
				or src:match("^%.%d+", i)
			local after = i + #num
			if src:sub(after, after) == ":" and src:sub(after + 1, after + 1):match("%d") then
				local num2 = src:match("^%d+", after + 1)
				local r1, r2 = tonumber(num), tonumber(num2)
				toks[#toks + 1] = {
					t = "ref",
					v = {
						__ref = "range",
						c1 = 1,
						r1 = math.min(r1, r2),
						c2 = MAXCOL,
						r2 = math.max(r1, r2),
						fullRow = true,
					},
				}
				i = after + 1 + #num2
			else
				toks[#toks + 1] = { t = "num", v = tonumber(num) }
				i = after
			end
		elseif c == "$" or c == "'" or c:match("%a") then
			local ref, len = scan_reference(src, i)
			if ref then
				toks[#toks + 1] = { t = "ref", v = ref }
				i += len
			else
				-- a name: TRUE/FALSE literal, a function name, or a defined name
				local name = src:match("^([%a_][%w_.]*)", i)
				if not name then
					return nil, ERR.ERROR
				end
				local up = name:upper()
				if up == "TRUE" then
					toks[#toks + 1] = { t = "bool", v = true }
				elseif up == "FALSE" then
					toks[#toks + 1] = { t = "bool", v = false }
				else
					toks[#toks + 1] = { t = "name", v = name }
				end
				i += #name
			end
		elseif c == "(" then
			toks[#toks + 1] = { t = "(" }
			i += 1
		elseif c == ")" then
			toks[#toks + 1] = { t = ")" }
			i += 1
		elseif c == "," then
			toks[#toks + 1] = { t = "," }
			i += 1
		elseif c == "{" then
			toks[#toks + 1] = { t = "{" }
			i += 1
		elseif c == "}" then
			toks[#toks + 1] = { t = "}" }
			i += 1
		elseif c == ";" then
			toks[#toks + 1] = { t = ";" }
			i += 1
		else
			-- operators: <> <= >= and single-char + - * / ^ & = < > %
			local two = src:sub(i, i + 1)
			if two == "<>" or two == "<=" or two == ">=" then
				toks[#toks + 1] = { t = "op", v = two }
				i += 2
			elseif c:match("[%+%-%*/%^&=<>%%]") then
				toks[#toks + 1] = { t = "op", v = c }
				i += 1
			else
				return nil, ERR.ERROR
			end
		end
	end
	return toks
end

-- ===========================================================================
-- Parser (precedence-climbing → typed AST)
-- ===========================================================================

-- Left binding power of an infix/postfix operator.
local LBP = {
	["="] = 10,
	["<>"] = 10,
	["<"] = 10,
	[">"] = 10,
	["<="] = 10,
	[">="] = 10,
	["&"] = 20,
	["+"] = 30,
	["-"] = 30,
	["*"] = 40,
	["/"] = 40,
	["^"] = 50,
	["%"] = 60,
}
local UNARY_BP = 55 -- unary +/- binds tighter than ^ (so -2^2 == 4, like Excel)

local function new_parser(toks)
	return { toks = toks, pos = 1 }
end
local function peek(p)
	return p.toks[p.pos]
end
local function advance(p)
	local t = p.toks[p.pos]
	p.pos += 1
	return t
end

local parse_expr -- forward

-- nud — a prefix / atom.
local function parse_nud(p)
	local tk = advance(p)
	if not tk then
		error(ERR.ERROR)
	end
	if tk.t == "num" then
		return { kind = "num", value = tk.v }
	end
	if tk.t == "str" then
		return { kind = "str", value = tk.v }
	end
	if tk.t == "bool" then
		return { kind = "bool", value = tk.v }
	end
	if tk.t == "err" then
		return { kind = "err", value = tk.v }
	end
	if tk.t == "ref" then
		if tk.v.__ref == "range" then
			return { kind = "range", ref = tk.v }
		end
		return { kind = "ref", ref = tk.v }
	end
	if tk.t == "name" then
		if peek(p) and peek(p).t == "(" then
			advance(p) -- consume "("
			local args = {}
			if not (peek(p) and peek(p).t == ")") then
				while true do
					-- support omitted args: SUM(1,,3)
					if peek(p) and (peek(p).t == "," or peek(p).t == ")") then
						args[#args + 1] = { kind = "missing" }
					else
						args[#args + 1] = parse_expr(p, 0)
					end
					local nx = peek(p)
					if nx and nx.t == "," then
						advance(p)
					else
						break
					end
				end
			end
			local close = advance(p)
			if not close or close.t ~= ")" then
				error(ERR.ERROR)
			end
			return { kind = "call", name = tk.v:upper(), args = args }
		end
		return { kind = "name", name = tk.v }
	end
	if tk.t == "(" then
		local e = parse_expr(p, 0)
		local close = advance(p)
		if not close or close.t ~= ")" then
			error(ERR.ERROR)
		end
		return e
	end
	if tk.t == "{" then
		-- an array constant {1,2;3,4} — rows by ";", columns by ",", literals only
		local rows, cur = {}, {}
		while true do
			cur[#cur + 1] = parse_expr(p, 0)
			local nx = advance(p)
			if not nx then
				error(ERR.ERROR)
			end
			if nx.t == "," then
				-- next column
			elseif nx.t == ";" then
				rows[#rows + 1] = cur
				cur = {}
			elseif nx.t == "}" then
				rows[#rows + 1] = cur
				break
			else
				error(ERR.ERROR)
			end
		end
		return { kind = "arrayconst", rows = rows }
	end
	if tk.t == "op" and (tk.v == "-" or tk.v == "+") then
		local operand = parse_expr(p, UNARY_BP)
		return { kind = "unary", op = tk.v, operand = operand }
	end
	error(ERR.ERROR)
end

-- led — an infix / postfix continuation of `left`.
local function parse_led(p, left)
	local tk = advance(p)
	if tk.v == "%" then
		return { kind = "postfix", op = "%", operand = left }
	end
	local rbp = LBP[tk.v]
	if tk.v == "^" then
		rbp -= 1
	end -- right-associative
	local right = parse_expr(p, rbp)
	return { kind = "binary", op = tk.v, left = left, right = right }
end

function parse_expr(p, rbp)
	local left = parse_nud(p)
	while true do
		local nx = peek(p)
		if not nx or nx.t ~= "op" then
			break
		end
		local lbp = LBP[nx.v]
		if not lbp or lbp <= rbp then
			break
		end
		left = parse_led(p, left)
	end
	return left
end

-- calc.parse(src) → ast | nil, errValue. A leading "=" / "+" is stripped.
function calc.parse(src)
	if type(src) ~= "string" then
		return nil, ERR.ERROR
	end
	src = src:gsub("^%s*=", "")
	local toks, err = tokenize(src)
	if not toks then
		return nil, err
	end
	if #toks == 0 then
		return { kind = "blank" }, nil
	end
	local p = new_parser(toks)
	local ok, ast = pcall(parse_expr, p, 0)
	if not ok then
		return nil, (is_error(ast) and ast or ERR.ERROR)
	end
	if p.pos <= #toks then
		return nil, ERR.ERROR
	end -- trailing tokens
	return ast, nil
end

-- ===========================================================================
-- Dependency extraction (cells/ranges a formula reads — for the recalc graph)
-- ===========================================================================

-- calc.deps(ast) → { {kind="cell"|"range", sheet?, …}, … } (de-duplication is the
-- caller's concern). Walks the AST collecting ref/range nodes.
function calc.deps(ast)
	local out = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		local k = node.kind
		if k == "ref" then
			out[#out + 1] =
				{ kind = "cell", sheet = node.ref.sheet, col = node.ref.col, row = node.ref.row }
		elseif k == "range" then
			local r = node.ref
			out[#out + 1] =
				{ kind = "range", sheet = r.sheet, c1 = r.c1, r1 = r.r1, c2 = r.c2, r2 = r.r2 }
		elseif k == "unary" or k == "postfix" then
			walk(node.operand)
		elseif k == "binary" then
			walk(node.left)
			walk(node.right)
		elseif k == "call" then
			for _, a in ipairs(node.args) do
				walk(a)
			end
		end
	end
	walk(ast)
	return out
end

-- ===========================================================================
-- Evaluator
-- ===========================================================================

-- Dereference a Value to a scalar (ref-cell → its content; ref-range / array →
-- top-left, mirroring fast-formula-parser's isArray → [0][0]).
local function as_scalar(v, ctx)
	if is_ref(v) then
		if v.__ref == "cell" then
			return ctx.cell(v.sheet, v.col, v.row)
		end
		return ctx.cell(v.sheet, v.c1, v.r1) -- range in scalar context → top-left
	end
	if is_array(v) then
		local cell = v.data[1] and v.data[1][1]
		return cell == nil and BLANK or cell
	end
	return v
end

-- Dereference a Value to a 2-D array (ref-range → the grid; ref-cell → 1×1; scalar →
-- 1×1). Used by aggregations / array-aware functions.
local function as_array(v, ctx)
	if is_ref(v) then
		if v.__ref == "cell" then
			return mkarray({ { ctx.cell(v.sheet, v.col, v.row) } })
		end
		return ctx.range(v.sheet, v.c1, v.r1, v.c2, v.r2)
	end
	if is_array(v) then
		return v
	end
	return mkarray({ { v } })
end

local evaluate -- forward

-- Apply a binary operator to two already-evaluated operands (ported from
-- operators.js: math / compare / concat, with the cross-type comparison ordering).
local TYPE_ORDER = { number = 1, string = 2, boolean = 3 }
local function apply_binary(op, lv, rv, ctx)
	lv, rv = as_scalar(lv, ctx), as_scalar(rv, ctx)
	if is_error(lv) then
		return lv
	end
	if is_error(rv) then
		return rv
	end
	if op == "&" then
		return to_string(is_blank(lv) and "" or lv) .. to_string(is_blank(rv) and "" or rv)
	end
	if op == "=" or op == "<>" or op == "<" or op == ">" or op == "<=" or op == ">=" then
		local a = is_blank(lv) and 0 or lv
		local b = is_blank(rv) and 0 or rv
		local ta, tb = type(a), type(b)
		if ta == tb then
			-- case-insensitive string comparison (Excel)
			if ta == "string" then
				a, b = a:upper(), b:upper()
			end
			if op == "=" then
				return a == b
			end
			if op == "<>" then
				return a ~= b
			end
			if op == "<" then
				return a < b
			end
			if op == ">" then
				return a > b
			end
			if op == "<=" then
				return a <= b
			end
			if op == ">=" then
				return a >= b
			end
		else
			local oa, ob = TYPE_ORDER[ta] or 0, TYPE_ORDER[tb] or 0
			if op == "=" then
				return false
			end
			if op == "<>" then
				return true
			end
			if op == ">" then
				return oa > ob
			end
			if op == "<" then
				return oa < ob
			end
			if op == ">=" then
				return oa >= ob
			end
			if op == "<=" then
				return oa <= ob
			end
		end
	end
	-- arithmetic
	local a, b = to_number(lv), to_number(rv)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	if op == "+" then
		return a + b
	end
	if op == "-" then
		return a - b
	end
	if op == "*" then
		return a * b
	end
	if op == "/" then
		if b == 0 then
			return ERR.DIV0
		end
		return a / b
	end
	if op == "^" then
		local r = a ^ b
		if r ~= r then
			return ERR.NUM
		end -- NaN (e.g. (-1)^0.5)
		return r
	end
	return ERR.ERROR
end

-- A multi-cell operand (a range ref or an array), else nil (scalar). Used to decide
-- whether a binary operator broadcasts (dynamic arrays).
local function operand_array(v, ctx)
	if is_ref(v) and v.__ref == "range" then
		local a = as_array(v, ctx)
		if a.rows > 1 or a.cols > 1 then
			return a
		end
	elseif is_array(v) and (v.rows > 1 or v.cols > 1) then
		return v
	end
	return nil
end

-- Apply a binary operator element-wise, broadcasting a scalar across an array and
-- pairing same-shape arrays (dynamic-array semantics; mismatched dims reuse the
-- nearest index — a pragmatic broadcast).
local function broadcast_binary(op, lv, rv, la, ra, ctx)
	local lr, lc = la and la.rows or 1, la and la.cols or 1
	local rr, rc = ra and ra.rows or 1, ra and ra.cols or 1
	local rows, cols = math.max(lr, rr), math.max(lc, rc)
	local data = {}
	for r = 1, rows do
		local rowd = {}
		for c = 1, cols do
			local le = la and la.data[math.min(r, lr)][math.min(c, lc)] or lv
			local re = ra and ra.data[math.min(r, rr)][math.min(c, rc)] or rv
			rowd[c] = apply_binary(op, le, re, ctx)
		end
		data[r] = rowd
	end
	return mkarray(data)
end

-- The function registry, defined below; referenced by evaluate.
local FUNCTIONS = {}
calc.functions = FUNCTIONS

evaluate = function(node, ctx)
	local k = node.kind
	if k == "num" or k == "str" or k == "bool" then
		return node.value
	end
	if k == "err" then
		return node.value
	end
	if k == "blank" or k == "missing" then
		return BLANK
	end
	if k == "ref" or k == "range" then
		return node.ref
	end
	if k == "arrayconst" then
		local data = {}
		for _, row in ipairs(node.rows) do
			local rowd = {}
			for _, el in ipairs(row) do
				rowd[#rowd + 1] = as_scalar(evaluate(el, ctx), ctx)
			end
			data[#data + 1] = rowd
		end
		return mkarray(data)
	end
	if k == "name" then
		-- a defined name → resolve to a ref/formula via ctx.name, then evaluate
		if ctx.name then
			local resolved = ctx.name(node.name)
			if resolved ~= nil then
				if type(resolved) == "string" then
					local ast, err = calc.parse(resolved)
					if not ast then
						return err
					end
					return evaluate(ast, ctx)
				end
				return resolved
			end
		end
		return ERR.NAME
	end
	if k == "unary" then
		local v = as_scalar(evaluate(node.operand, ctx), ctx)
		if is_error(v) then
			return v
		end
		local nval = to_number(v)
		if is_error(nval) then
			return nval
		end
		return node.op == "-" and -nval or nval
	end
	if k == "postfix" then -- only "%"
		local v = as_scalar(evaluate(node.operand, ctx), ctx)
		if is_error(v) then
			return v
		end
		local nval = to_number(v)
		if is_error(nval) then
			return nval
		end
		return nval / 100
	end
	if k == "binary" then
		local lv, rv = evaluate(node.left, ctx), evaluate(node.right, ctx)
		local la, ra = operand_array(lv, ctx), operand_array(rv, ctx)
		if la or ra then
			return broadcast_binary(node.op, lv, rv, la, ra, ctx)
		end
		return apply_binary(node.op, lv, rv, ctx)
	end
	if k == "call" then
		local f = FUNCTIONS[node.name]
		if not f then
			return ERR.NAME
		end
		if f.lazy then
			return f.fn(node.args, ctx, evaluate)
		end
		local args = {}
		for i, a in ipairs(node.args) do
			args[i] = evaluate(a, ctx)
			if not f.errorAware then
				local s = is_array(args[i]) and nil or (is_ref(args[i]) and nil or args[i])
				if is_error(s) then
					return s
				end
			end
		end
		return f.fn(args, ctx)
	end
	return ERR.ERROR
end
calc.evaluate = evaluate

-- Resolve a formula's TOP-LEVEL result: a bare reference (e.g. =A1, or OFFSET/
-- INDIRECT) dereferences to its value/array; everything else passes through. Arrays
-- are kept (the host spills them — dynamic arrays).
function calc.finalize(v, ctx)
	if is_ref(v) then
		if v.__ref == "cell" then
			return ctx.cell(v.sheet, v.col, v.row)
		end
		return as_array(v, ctx) -- a range result → its 2-D array (spillable)
	end
	return v
end

-- calc.eval(src, ctx) → Value. Parses then evaluates; a parse error becomes the
-- corresponding error Value (so callers always get a Value, never a raised error).
function calc.eval(src, ctx)
	local ast, err = calc.parse(src)
	if not ast then
		return err
	end
	return calc.finalize(evaluate(ast, ctx), ctx)
end

-- ===========================================================================
-- Function helpers + registry (Tier-C; ported from formulajs / fast-formula-parser)
-- ===========================================================================

local register -- forward (defines a function with metadata)

-- Flatten args into a stream, invoking `visit(value, fromRef)` for each scalar.
-- `fromRef` is true when the value came from a range/array (so aggregations can skip
-- text/booleans the way Excel does). Returns an error if one is encountered.
local function for_each_value(args, ctx, visit)
	for _, arg in ipairs(args) do
		if is_ref(arg) or is_array(arg) then
			local arr = as_array(arg, ctx)
			for r = 1, arr.rows do
				local rowd = arr.data[r]
				for c = 1, arr.cols do
					local v = rowd[c]
					if is_error(v) then
						return v
					end
					visit(v, true)
				end
			end
		else
			if is_error(arg) then
				return arg
			end
			visit(arg, false)
		end
	end
	return nil
end

-- Collect numbers for an aggregation. From references/arrays only real numbers count
-- (text / blank / boolean skipped — Excel's SUM/AVERAGE rule); literal scalars are
-- coerced (boolean → 1/0, numeric string → number, blank → skipped). Errors
-- propagate. Returns (numbers[], err).
local function collect_numbers(args, ctx)
	local nums = {}
	local err = for_each_value(args, ctx, function(v, fromRef)
		if type(v) == "number" then
			nums[#nums + 1] = v
		elseif not fromRef then
			if type(v) == "boolean" then
				nums[#nums + 1] = v and 1 or 0
			elseif type(v) == "string" and v ~= "" then
				local n = tonumber(v)
				if n then
					nums[#nums + 1] = n
				end
			end
		end
	end)
	return nums, err
end

-- A single scalar argument coerced to number (literal or single-cell ref).
local function arg_number(arg, ctx)
	return to_number(as_scalar(arg, ctx))
end
local function arg_string(arg, ctx)
	return to_string(as_scalar(arg, ctx))
end
local function arg_int(arg, ctx)
	local n = arg_number(arg, ctx)
	if is_error(n) then
		return n
	end
	return math.floor(n)
end

function register(names, fn, opts)
	opts = opts or {}
	if type(names) == "string" then
		names = { names }
	end
	for _, nm in ipairs(names) do
		FUNCTIONS[nm] = { fn = fn, lazy = opts.lazy, errorAware = opts.errorAware }
	end
end

-- ---- math / statistical aggregations ----------------------------------------

register("SUM", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	local s = 0
	for _, n in ipairs(nums) do
		s += n
	end
	return s
end)

register("PRODUCT", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	if #nums == 0 then
		return 0
	end
	local p = 1
	for _, n in ipairs(nums) do
		p *= n
	end
	return p
end)

register({ "AVERAGE", "AVG" }, function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	if #nums == 0 then
		return ERR.DIV0
	end
	local s = 0
	for _, n in ipairs(nums) do
		s += n
	end
	return s / #nums
end)

register("MIN", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	if #nums == 0 then
		return 0
	end
	local m = nums[1]
	for _, n in ipairs(nums) do
		if n < m then
			m = n
		end
	end
	return m
end)

register("MAX", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	if #nums == 0 then
		return 0
	end
	local m = nums[1]
	for _, n in ipairs(nums) do
		if n > m then
			m = n
		end
	end
	return m
end)

register("MEDIAN", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	if #nums == 0 then
		return ERR.NUM
	end
	table.sort(nums)
	local mid = #nums // 2
	if #nums % 2 == 1 then
		return nums[mid + 1]
	end
	return (nums[mid] + nums[mid + 1]) / 2
end)

-- COUNT (numbers only) / COUNTA (non-blank) / COUNTBLANK.
register("COUNT", function(args, ctx)
	local count = 0
	local err = for_each_value(args, ctx, function(v, fromRef)
		if type(v) == "number" then
			count += 1
		elseif not fromRef and type(v) == "string" and tonumber(v) then
			count += 1
		elseif not fromRef and type(v) == "boolean" then
			count += 1
		end
	end)
	if err then
		return err
	end
	return count
end)

register("COUNTA", function(args, ctx)
	local count = 0
	for_each_value(args, ctx, function(v)
		if not is_blank(v) then
			count += 1
		end
	end)
	return count
end)

register("COUNTBLANK", function(args, ctx)
	local count = 0
	for _, arg in ipairs(args) do
		local arr = as_array(arg, ctx)
		for r = 1, arr.rows do
			for c = 1, arr.cols do
				local v = arr.data[r][c]
				if is_blank(v) or v == "" then
					count += 1
				end
			end
		end
	end
	return count
end)

-- ---- rounding / number theory -----------------------------------------------

local function round_half_away(x, digits)
	local m = 10 ^ digits
	local y = x * m
	-- round half away from zero (Excel's ROUND)
	if y >= 0 then
		y = math.floor(y + 0.5)
	else
		y = math.ceil(y - 0.5)
	end
	return y / m
end

-- Read an optional digits argument (a Value, not a node) defaulting to 0.
local function arg_digits(args, idx, ctx)
	if args[idx] == nil then
		return 0
	end
	return arg_int(args[idx], ctx)
end

register("ROUND", function(args, ctx)
	local n, d = arg_number(args[1], ctx), arg_digits(args, 2, ctx)
	if is_error(n) then
		return n
	end
	if is_error(d) then
		return d
	end
	return round_half_away(n, d)
end)
register("ROUNDUP", function(args, ctx)
	local n, d = arg_number(args[1], ctx), arg_digits(args, 2, ctx)
	if is_error(n) then
		return n
	end
	if is_error(d) then
		return d
	end
	local m = 10 ^ d
	local y = n * m
	y = (y >= 0) and math.ceil(y) or math.floor(y)
	return y / m
end)
register("ROUNDDOWN", function(args, ctx)
	local n, d = arg_number(args[1], ctx), arg_digits(args, 2, ctx)
	if is_error(n) then
		return n
	end
	if is_error(d) then
		return d
	end
	local m = 10 ^ d
	local y = n * m
	y = (y >= 0) and math.floor(y) or math.ceil(y)
	return y / m
end)

register("INT", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return math.floor(n)
end)
register("TRUNC", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	local d = args[2] and arg_int(args[2], ctx) or 0
	if is_error(d) then
		return d
	end
	local m = 10 ^ d
	local y = n * m
	y = (y >= 0) and math.floor(y) or math.ceil(y)
	return y / m
end)
register("ABS", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return math.abs(n)
end)
register("SIGN", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return (n > 0) and 1 or (n < 0) and -1 or 0
end)
register("MOD", function(args, ctx)
	local a, b = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	if b == 0 then
		return ERR.DIV0
	end
	return a - b * math.floor(a / b) -- Excel MOD takes the sign of the divisor
end)
register("POWER", function(args, ctx)
	local a, b = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	local r = a ^ b
	if r ~= r then
		return ERR.NUM
	end
	return r
end)
register({ "SQRT" }, function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	if n < 0 then
		return ERR.NUM
	end
	return math.sqrt(n)
end)
register("EXP", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return math.exp(n)
end)
register("LN", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	if n <= 0 then
		return ERR.NUM
	end
	return math.log(n)
end)
register("LOG10", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	if n <= 0 then
		return ERR.NUM
	end
	return math.log(n) / math.log(10)
end)
register("LOG", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	local base = args[2] and arg_number(args[2], ctx) or 10
	if is_error(base) then
		return base
	end
	if n <= 0 then
		return ERR.NUM
	end
	return math.log(n) / math.log(base)
end)
register("CEILING", function(args, ctx)
	local n = arg_number(args[1], ctx)
	local sig = args[2] and arg_number(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if is_error(sig) then
		return sig
	end
	if sig == 0 then
		return 0
	end
	return math.ceil(n / sig) * sig
end)
register("FLOOR", function(args, ctx)
	local n = arg_number(args[1], ctx)
	local sig = args[2] and arg_number(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if is_error(sig) then
		return sig
	end
	if sig == 0 then
		return ERR.DIV0
	end
	return math.floor(n / sig) * sig
end)

-- ---- criteria-based aggregations (SUMIF / COUNTIF / AVERAGEIF) ---------------

-- Compile an Excel criterion (">5", "<>x", "apple", 10) → a predicate(value).
local function make_criterion(crit)
	if is_blank(crit) then
		crit = ""
	end
	if type(crit) == "number" or type(crit) == "boolean" then
		return function(v)
			return v == crit
		end
	end
	local s = tostring(crit)
	local op, rest = s:match("^(<=)(.*)$")
	if not op then
		op, rest = s:match("^(>=)(.*)$")
	end
	if not op then
		op, rest = s:match("^(<>)(.*)$")
	end
	if not op then
		op, rest = s:match("^([<>=])(.*)$")
	end
	if not op then
		op, rest = "=", s
	end
	local numTarget = tonumber(rest)
	return function(v)
		if op == "=" then
			if numTarget ~= nil and type(v) == "number" then
				return v == numTarget
			end
			return type(v) == "string" and v:upper() == rest:upper() or v == rest
		elseif op == "<>" then
			if numTarget ~= nil and type(v) == "number" then
				return v ~= numTarget
			end
			return not (type(v) == "string" and v:upper() == rest:upper()) and v ~= rest
		else
			if type(v) ~= "number" or numTarget == nil then
				return false
			end
			if op == ">" then
				return v > numTarget
			end
			if op == "<" then
				return v < numTarget
			end
			if op == ">=" then
				return v >= numTarget
			end
			if op == "<=" then
				return v <= numTarget
			end
		end
		return false
	end
end

-- Iterate a range argument's cells as a flat list (preserving blanks as BLANK).
local function range_values(arg, ctx)
	local arr = as_array(arg, ctx)
	local out = {}
	for r = 1, arr.rows do
		for c = 1, arr.cols do
			out[#out + 1] = arr.data[r][c]
		end
	end
	return out
end

register("COUNTIF", function(args, ctx)
	local vals = range_values(args[1], ctx)
	local pred = make_criterion(as_scalar(args[2], ctx))
	local count = 0
	for _, v in ipairs(vals) do
		if not is_blank(v) and pred(v) then
			count += 1
		end
	end
	return count
end)

register("SUMIF", function(args, ctx)
	local crange = range_values(args[1], ctx)
	local pred = make_criterion(as_scalar(args[2], ctx))
	local srange = args[3] and range_values(args[3], ctx) or crange
	local sum = 0
	for i, v in ipairs(crange) do
		if not is_blank(v) and pred(v) then
			local sv = srange[i]
			if type(sv) == "number" then
				sum += sv
			end
		end
	end
	return sum
end)

register("AVERAGEIF", function(args, ctx)
	local crange = range_values(args[1], ctx)
	local pred = make_criterion(as_scalar(args[2], ctx))
	local srange = args[3] and range_values(args[3], ctx) or crange
	local sum, n = 0, 0
	for i, v in ipairs(crange) do
		if not is_blank(v) and pred(v) then
			local sv = srange[i]
			if type(sv) == "number" then
				sum += sv
				n += 1
			end
		end
	end
	if n == 0 then
		return ERR.DIV0
	end
	return sum / n
end)

register("SUMPRODUCT", function(args, ctx)
	if #args == 0 then
		return ERR.VALUE
	end
	local arrs = {}
	for _, a in ipairs(args) do
		arrs[#arrs + 1] = as_array(a, ctx)
	end
	local rows, cols = arrs[1].rows, arrs[1].cols
	local total = 0
	for r = 1, rows do
		for c = 1, cols do
			local prod = 1
			for _, arr in ipairs(arrs) do
				local v = arr.data[r] and arr.data[r][c]
				if is_error(v) then
					return v
				end
				prod *= (type(v) == "number") and v or 0
			end
			total += prod
		end
	end
	return total
end)

-- ---- logical (lazy / short-circuit) -----------------------------------------

register("IF", function(argNodes, ctx, ev)
	if #argNodes < 2 then
		return ERR.VALUE
	end
	local cond = to_boolean(as_scalar(ev(argNodes[1], ctx), ctx))
	if is_error(cond) then
		return cond
	end
	if cond then
		return as_scalar(ev(argNodes[2], ctx), ctx)
	elseif argNodes[3] then
		return as_scalar(ev(argNodes[3], ctx), ctx)
	end
	return false
end, { lazy = true })

register("IFS", function(argNodes, ctx, ev)
	local i = 1
	while i + 1 <= #argNodes do
		local cond = to_boolean(as_scalar(ev(argNodes[i], ctx), ctx))
		if is_error(cond) then
			return cond
		end
		if cond then
			return as_scalar(ev(argNodes[i + 1], ctx), ctx)
		end
		i += 2
	end
	return ERR.NA
end, { lazy = true })

register("IFERROR", function(argNodes, ctx, ev)
	local v = as_scalar(ev(argNodes[1], ctx), ctx)
	if is_error(v) then
		return argNodes[2] and as_scalar(ev(argNodes[2], ctx), ctx) or ""
	end
	return v
end, { lazy = true })

register("IFNA", function(argNodes, ctx, ev)
	local v = as_scalar(ev(argNodes[1], ctx), ctx)
	if is_error(v) and v.code == "#N/A" then
		return argNodes[2] and as_scalar(ev(argNodes[2], ctx), ctx) or ""
	end
	return v
end, { lazy = true })

register("AND", function(args, ctx)
	local any = false
	local result = true
	local err = for_each_value(args, ctx, function(v, fromRef)
		if type(v) == "boolean" or type(v) == "number" or (not fromRef and type(v) == "string") then
			local b = to_boolean(v)
			if not is_error(b) then
				any = true
				if not b then
					result = false
				end
			end
		end
	end)
	if err then
		return err
	end
	if not any then
		return ERR.VALUE
	end
	return result
end)

register("OR", function(args, ctx)
	local any = false
	local result = false
	local err = for_each_value(args, ctx, function(v, fromRef)
		if type(v) == "boolean" or type(v) == "number" or (not fromRef and type(v) == "string") then
			local b = to_boolean(v)
			if not is_error(b) then
				any = true
				if b then
					result = true
				end
			end
		end
	end)
	if err then
		return err
	end
	if not any then
		return ERR.VALUE
	end
	return result
end)

register("XOR", function(args, ctx)
	local trues = 0
	local any = false
	local err = for_each_value(args, ctx, function(v)
		if type(v) == "boolean" or type(v) == "number" then
			any = true
			if to_boolean(v) == true then
				trues += 1
			end
		end
	end)
	if err then
		return err
	end
	if not any then
		return ERR.VALUE
	end
	return (trues % 2) == 1
end)

register("NOT", function(args, ctx)
	local b = to_boolean(as_scalar(args[1], ctx))
	if is_error(b) then
		return b
	end
	return not b
end)
register("TRUE", function()
	return true
end)
register("FALSE", function()
	return false
end)

register("SWITCH", function(argNodes, ctx, ev)
	if #argNodes < 3 then
		return ERR.NA
	end
	local subject = as_scalar(ev(argNodes[1], ctx), ctx)
	local i = 2
	while i + 1 <= #argNodes do
		local match = as_scalar(ev(argNodes[i], ctx), ctx)
		if subject == match then
			return as_scalar(ev(argNodes[i + 1], ctx), ctx)
		end
		i += 2
	end
	if i <= #argNodes then
		return as_scalar(ev(argNodes[i], ctx), ctx)
	end -- default
	return ERR.NA
end, { lazy = true })

-- ---- text -------------------------------------------------------------------

register({ "CONCAT", "CONCATENATE" }, function(args, ctx)
	local parts = {}
	local err = for_each_value(args, ctx, function(v)
		parts[#parts + 1] = to_string(is_blank(v) and "" or v)
	end)
	if err then
		return err
	end
	return table.concat(parts)
end)

register("TEXTJOIN", function(args, ctx)
	local delim = arg_string(args[1], ctx)
	if is_error(delim) then
		return delim
	end
	local ignoreEmpty = to_boolean(as_scalar(args[2], ctx))
	local parts = {}
	for i = 3, #args do
		local arr = as_array(args[i], ctx)
		for r = 1, arr.rows do
			for c = 1, arr.cols do
				local v = arr.data[r][c]
				if is_error(v) then
					return v
				end
				local s = to_string(is_blank(v) and "" or v)
				if not (ignoreEmpty and s == "") then
					parts[#parts + 1] = s
				end
			end
		end
	end
	return table.concat(parts, delim)
end)

register("LEN", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return #s
end)
register("LEFT", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local n = args[2] and arg_int(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if n < 0 then
		return ERR.VALUE
	end
	return s:sub(1, n)
end)
register("RIGHT", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local n = args[2] and arg_int(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if n < 0 then
		return ERR.VALUE
	end
	if n == 0 then
		return ""
	end
	return s:sub(-n)
end)
register("MID", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local start = arg_int(args[2], ctx)
	local len = arg_int(args[3], ctx)
	if is_error(start) then
		return start
	end
	if is_error(len) then
		return len
	end
	if start < 1 or len < 0 then
		return ERR.VALUE
	end
	return s:sub(start, start + len - 1)
end)
register("UPPER", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return s:upper()
end)
register("LOWER", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return s:lower()
end)
register("PROPER", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return (s:gsub("(%a)([%w]*)", function(a, b)
		return a:upper() .. b:lower()
	end))
end)
register("TRIM", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end)
register("REPT", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local n = arg_int(args[2], ctx)
	if is_error(n) then
		return n
	end
	if n < 0 then
		return ERR.VALUE
	end
	return string.rep(s, n)
end)
register("EXACT", function(args, ctx)
	local a, b = arg_string(args[1], ctx), arg_string(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	return a == b
end)
register("SUBSTITUTE", function(args, ctx)
	local s, old, new = arg_string(args[1], ctx), arg_string(args[2], ctx), arg_string(args[3], ctx)
	if is_error(s) then
		return s
	end
	if is_error(old) then
		return old
	end
	if is_error(new) then
		return new
	end
	if old == "" then
		return s
	end
	-- plain (non-pattern) replacement
	local out, idx = {}, 1
	while true do
		local f = s:find(old, idx, true)
		if not f then
			out[#out + 1] = s:sub(idx)
			break
		end
		out[#out + 1] = s:sub(idx, f - 1)
		out[#out + 1] = new
		idx = f + #old
	end
	return table.concat(out)
end)
register("FIND", function(args, ctx)
	local needle, hay = arg_string(args[1], ctx), arg_string(args[2], ctx)
	if is_error(needle) then
		return needle
	end
	if is_error(hay) then
		return hay
	end
	local start = args[3] and arg_int(args[3], ctx) or 1
	if is_error(start) then
		return start
	end
	local f = hay:find(needle, start, true) -- case-sensitive, literal
	if not f then
		return ERR.VALUE
	end
	return f
end)
register("SEARCH", function(args, ctx)
	local needle, hay = arg_string(args[1], ctx), arg_string(args[2], ctx)
	if is_error(needle) then
		return needle
	end
	if is_error(hay) then
		return hay
	end
	local start = args[3] and arg_int(args[3], ctx) or 1
	if is_error(start) then
		return start
	end
	local f = hay:lower():find(needle:lower(), start, true) -- case-insensitive
	if not f then
		return ERR.VALUE
	end
	return f
end)
register("VALUE", function(args, ctx)
	local s = as_scalar(args[1], ctx)
	if is_error(s) then
		return s
	end
	if type(s) == "number" then
		return s
	end
	local n = tonumber(tostring(s))
	if n == nil then
		return ERR.VALUE
	end
	return n
end)
register("TEXT", function(args, ctx)
	-- minimal: numeric General formatting; full format codes are a follow-on
	local v = as_scalar(args[1], ctx)
	if is_error(v) then
		return v
	end
	return to_string(v)
end)

-- ---- information ------------------------------------------------------------

local function raw_arg(arg, ctx)
	return as_scalar(arg, ctx)
end
register("ISBLANK", function(args, ctx)
	return is_blank(raw_arg(args[1], ctx))
end, { errorAware = true })
register("ISNUMBER", function(args, ctx)
	return type(raw_arg(args[1], ctx)) == "number"
end, { errorAware = true })
register("ISTEXT", function(args, ctx)
	return type(raw_arg(args[1], ctx)) == "string"
end, { errorAware = true })
register("ISLOGICAL", function(args, ctx)
	return type(raw_arg(args[1], ctx)) == "boolean"
end, { errorAware = true })
register("ISERROR", function(args, ctx)
	return is_error(raw_arg(args[1], ctx))
end, { errorAware = true })
register("ISERR", function(args, ctx)
	local v = raw_arg(args[1], ctx)
	return is_error(v) and v.code ~= "#N/A"
end, { errorAware = true })
register("ISNA", function(args, ctx)
	local v = raw_arg(args[1], ctx)
	return is_error(v) and v.code == "#N/A"
end, { errorAware = true })
register("NA", function()
	return ERR.NA
end)
register("N", function(args, ctx)
	local v = as_scalar(args[1], ctx)
	if is_error(v) then
		return v
	end
	if type(v) == "number" then
		return v
	end
	if type(v) == "boolean" then
		return v and 1 or 0
	end
	return 0
end)
register("TYPE", function(args, ctx)
	local v = as_scalar(args[1], ctx)
	if type(v) == "number" then
		return 1
	end
	if type(v) == "string" then
		return 2
	end
	if type(v) == "boolean" then
		return 4
	end
	if is_error(v) then
		return 16
	end
	return 1
end, { errorAware = true })

-- ---- lookup -----------------------------------------------------------------

register("CHOOSE", function(argNodes, ctx, ev)
	local idx = to_number(as_scalar(ev(argNodes[1], ctx), ctx))
	if is_error(idx) then
		return idx
	end
	idx = math.floor(idx)
	if idx < 1 or idx + 1 > #argNodes then
		return ERR.VALUE
	end
	return as_scalar(ev(argNodes[idx + 1], ctx), ctx)
end, { lazy = true })

-- VLOOKUP(value, table, colIndex, [rangeLookup]) — exact match when rangeLookup is
-- FALSE; approximate (assumes sorted ascending) otherwise.
register("VLOOKUP", function(args, ctx)
	local key = as_scalar(args[1], ctx)
	if is_error(key) then
		return key
	end
	local arr = as_array(args[2], ctx)
	local colIdx = arg_int(args[3], ctx)
	if is_error(colIdx) then
		return colIdx
	end
	local approx = args[4] == nil or to_boolean(as_scalar(args[4], ctx)) == true
	if colIdx < 1 or colIdx > arr.cols then
		return ERR.REF
	end
	local function eqkey(a, b)
		if type(a) == "string" and type(b) == "string" then
			return a:upper() == b:upper()
		end
		return a == b
	end
	if not approx then
		for r = 1, arr.rows do
			if eqkey(arr.data[r][1], key) then
				return arr.data[r][colIdx]
			end
		end
		return ERR.NA
	end
	-- approximate: largest value ≤ key (assumes ascending first column)
	local best
	for r = 1, arr.rows do
		local v = arr.data[r][1]
		if type(v) == type(key) and v <= key then
			best = r
		elseif type(v) == type(key) and v > key then
			break
		end
	end
	if not best then
		return ERR.NA
	end
	return arr.data[best][colIdx]
end)

register("HLOOKUP", function(args, ctx)
	local key = as_scalar(args[1], ctx)
	if is_error(key) then
		return key
	end
	local arr = as_array(args[2], ctx)
	local rowIdx = arg_int(args[3], ctx)
	if is_error(rowIdx) then
		return rowIdx
	end
	local approx = args[4] == nil or to_boolean(as_scalar(args[4], ctx)) == true
	if rowIdx < 1 or rowIdx > arr.rows then
		return ERR.REF
	end
	local function eqkey(a, b)
		if type(a) == "string" and type(b) == "string" then
			return a:upper() == b:upper()
		end
		return a == b
	end
	if not approx then
		for c = 1, arr.cols do
			if eqkey(arr.data[1][c], key) then
				return arr.data[rowIdx][c]
			end
		end
		return ERR.NA
	end
	local best
	for c = 1, arr.cols do
		local v = arr.data[1][c]
		if type(v) == type(key) and v <= key then
			best = c
		elseif type(v) == type(key) and v > key then
			break
		end
	end
	if not best then
		return ERR.NA
	end
	return arr.data[rowIdx][best]
end)

register("INDEX", function(args, ctx)
	local arr = as_array(args[1], ctx)
	local rowNum = arg_int(args[2], ctx)
	if is_error(rowNum) then
		return rowNum
	end
	local colNum = args[3] and arg_int(args[3], ctx) or nil
	if colNum and is_error(colNum) then
		return colNum
	end
	if arr.rows == 1 and not colNum then
		colNum = rowNum
		rowNum = 1
	end
	if arr.cols == 1 and not colNum then
		colNum = 1
	end
	colNum = colNum or 1
	if rowNum < 1 or rowNum > arr.rows or colNum < 1 or colNum > arr.cols then
		return ERR.REF
	end
	return arr.data[rowNum][colNum]
end)

register("MATCH", function(args, ctx)
	local key = as_scalar(args[1], ctx)
	if is_error(key) then
		return key
	end
	local arr = as_array(args[2], ctx)
	local mtype = args[3] and arg_int(args[3], ctx) or 1
	if is_error(mtype) then
		return mtype
	end
	local flat = {}
	for r = 1, arr.rows do
		for c = 1, arr.cols do
			flat[#flat + 1] = arr.data[r][c]
		end
	end
	local function eq(a, b)
		if type(a) == "string" and type(b) == "string" then
			return a:upper() == b:upper()
		end
		return a == b
	end
	if mtype == 0 then
		for i, v in ipairs(flat) do
			if eq(v, key) then
				return i
			end
		end
		return ERR.NA
	elseif mtype == 1 then -- largest ≤ key, ascending
		local best
		for i, v in ipairs(flat) do
			if type(v) == type(key) and v <= key then
				best = i
			end
		end
		if not best then
			return ERR.NA
		end
		return best
	else -- mtype == -1: smallest ≥ key, descending
		local best
		for i, v in ipairs(flat) do
			if type(v) == type(key) and v >= key then
				best = i
			end
		end
		if not best then
			return ERR.NA
		end
		return best
	end
end)

register({ "ROWS" }, function(args, ctx)
	if is_ref(args[1]) and args[1].__ref == "range" then
		return args[1].r2 - args[1].r1 + 1
	end
	local arr = as_array(args[1], ctx)
	return arr.rows
end, { errorAware = true })
register({ "COLUMNS" }, function(args, ctx)
	if is_ref(args[1]) and args[1].__ref == "range" then
		return args[1].c2 - args[1].c1 + 1
	end
	local arr = as_array(args[1], ctx)
	return arr.cols
end, { errorAware = true })

-- ---- date / time (serial ↔ civil; Excel 1900 epoch) -------------------------

-- days from civil (Howard Hinnant's algorithm); the Excel serial epoch is
-- 1899-12-30 (so 1900-01-01 = serial 1, matching Excel's 1900 leap-year quirk).
local function days_from_civil(y, m, d)
	y = (m <= 2) and (y - 1) or y
	local era = ((y >= 0) and y or (y - 399)) // 400
	local yoe = y - era * 400
	local doy = (153 * ((m > 2) and (m - 3) or (m + 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end
local EXCEL_EPOCH = days_from_civil(1899, 12, 30)
local function civil_from_days(z)
	z += 719468
	local era = ((z >= 0) and z or (z - 146096)) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = (mp < 10) and (mp + 3) or (mp - 9)
	return ((m <= 2) and (y + 1) or y), m, d
end
local function serial_to_ymd(serial)
	return civil_from_days(math.floor(serial) + EXCEL_EPOCH)
end

register("DATE", function(args, ctx)
	local y, m, d = arg_int(args[1], ctx), arg_int(args[2], ctx), arg_int(args[3], ctx)
	if is_error(y) then
		return y
	end
	if is_error(m) then
		return m
	end
	if is_error(d) then
		return d
	end
	if y < 1900 then
		y += 1900
	end
	return days_from_civil(y, m, d) - EXCEL_EPOCH
end)
register("YEAR", function(args, ctx)
	local s = arg_number(args[1], ctx)
	if is_error(s) then
		return s
	end
	local y = serial_to_ymd(s)
	return y
end)
register("MONTH", function(args, ctx)
	local s = arg_number(args[1], ctx)
	if is_error(s) then
		return s
	end
	local _, m = serial_to_ymd(s)
	return m
end)
register("DAY", function(args, ctx)
	local s = arg_number(args[1], ctx)
	if is_error(s) then
		return s
	end
	local _, _, d = serial_to_ymd(s)
	return d
end)
register("WEEKDAY", function(args, ctx)
	local s = arg_int(args[1], ctx)
	if is_error(s) then
		return s
	end
	-- days_from_civil(1970,1,1)=0 is a Thursday; Excel default returns Sun=1..Sat=7
	local dfc = s + EXCEL_EPOCH
	return (dfc + 4) % 7 + 1
end)
register("EDATE", function(args, ctx)
	local s = arg_number(args[1], ctx)
	local months = arg_int(args[2], ctx)
	if is_error(s) then
		return s
	end
	if is_error(months) then
		return months
	end
	local y, m, d = serial_to_ymd(s)
	local total = (y * 12 + (m - 1)) + months
	local ny, nm = total // 12, total % 12 + 1
	-- clamp the day to the target month's length (Jan 31 +1mo → Feb 28)
	local nextY, nextM = (nm == 12) and ny + 1 or ny, (nm % 12) + 1
	local dim = (days_from_civil(nextY, nextM, 1) - days_from_civil(ny, nm, 1))
	if d > dim then
		d = dim
	end
	return days_from_civil(ny, nm, d) - EXCEL_EPOCH
end)
register("EOMONTH", function(args, ctx)
	local s = arg_number(args[1], ctx)
	local months = arg_int(args[2], ctx)
	if is_error(s) then
		return s
	end
	if is_error(months) then
		return months
	end
	local y, m = serial_to_ymd(s)
	local total = (y * 12 + (m - 1)) + months + 1
	local ny, nm = total // 12, total % 12 + 1
	return days_from_civil(ny, nm, 1) - EXCEL_EPOCH - 1
end)
register("TODAY", function(args, ctx)
	if ctx.now then
		return math.floor(ctx.now / 86400) + (days_from_civil(1970, 1, 1) - EXCEL_EPOCH)
	end
	return ERR.NA
end)
register("NOW", function(args, ctx)
	if ctx.now then
		return ctx.now / 86400 + (days_from_civil(1970, 1, 1) - EXCEL_EPOCH)
	end
	return ERR.NA
end)

calc.daysFromCivil = days_from_civil
calc.serialToYMD = serial_to_ymd

-- ===========================================================================
-- Tier-E function catalog (financial / statistical / math-trig / text /
-- information / lookup / date-time / engineering). Ported from formulajs /
-- fast-formula-parser; validated against the Python `formulas` oracle.
-- ===========================================================================

-- ---- statistical helpers ----------------------------------------------------

local function mean_of(nums)
	local s = 0
	for _, n in ipairs(nums) do
		s += n
	end
	return #nums > 0 and s / #nums or 0
end
local function variance_of(nums, sample)
	if #nums < (sample and 2 or 1) then
		return ERR.DIV0
	end
	local m = mean_of(nums)
	local s = 0
	for _, n in ipairs(nums) do
		s += (n - m) ^ 2
	end
	return s / (#nums - (sample and 1 or 0))
end

local function reg_stat(name, sample, sqrt)
	register(name, function(args, ctx)
		local nums, err = collect_numbers(args, ctx)
		if err then
			return err
		end
		local v = variance_of(nums, sample)
		if is_error(v) then
			return v
		end
		return sqrt and math.sqrt(v) or v
	end)
end
reg_stat({ "VAR", "VAR.S", "VARA" }, true, false)
reg_stat({ "VARP", "VAR.P", "VARPA" }, false, false)
reg_stat({ "STDEV", "STDEV.S", "STDEVA" }, true, true)
reg_stat({ "STDEVP", "STDEV.P", "STDEVPA" }, false, true)

register({ "LARGE" }, function(args, ctx)
	local nums = collect_numbers({ args[1] }, ctx)
	local k = arg_int(args[2], ctx)
	if is_error(k) then
		return k
	end
	if k < 1 or k > #nums then
		return ERR.NUM
	end
	table.sort(nums, function(a, b)
		return a > b
	end)
	return nums[k]
end)
register({ "SMALL" }, function(args, ctx)
	local nums = collect_numbers({ args[1] }, ctx)
	local k = arg_int(args[2], ctx)
	if is_error(k) then
		return k
	end
	if k < 1 or k > #nums then
		return ERR.NUM
	end
	table.sort(nums)
	return nums[k]
end)
register({ "RANK", "RANK.EQ" }, function(args, ctx)
	local x = arg_number(args[1], ctx)
	if is_error(x) then
		return x
	end
	local nums = collect_numbers({ args[2] }, ctx)
	local order = args[3] and arg_number(args[3], ctx) or 0
	local asc = type(order) == "number" and order ~= 0
	local rank = 1
	for _, n in ipairs(nums) do
		if asc then
			if n < x then
				rank += 1
			end
		else
			if n > x then
				rank += 1
			end
		end
	end
	-- ensure x is present
	for _, n in ipairs(nums) do
		if n == x then
			return rank
		end
	end
	return ERR.NA
end)
register("PERCENTILE", function(args, ctx)
	local nums = collect_numbers({ args[1] }, ctx)
	local p = arg_number(args[2], ctx)
	if is_error(p) then
		return p
	end
	if #nums == 0 or p < 0 or p > 1 then
		return ERR.NUM
	end
	table.sort(nums)
	local rank = p * (#nums - 1) + 1
	local lo = math.floor(rank)
	local frac = rank - lo
	if lo >= #nums then
		return nums[#nums]
	end
	return nums[lo] + frac * (nums[lo + 1] - nums[lo])
end)
FUNCTIONS["PERCENTILE.INC"] = FUNCTIONS["PERCENTILE"]
register("QUARTILE", function(args, ctx)
	local nums = collect_numbers({ args[1] }, ctx)
	local q = arg_int(args[2], ctx)
	if is_error(q) then
		return q
	end
	if #nums == 0 or q < 0 or q > 4 then
		return ERR.NUM
	end
	table.sort(nums)
	local p = q / 4
	local rank = p * (#nums - 1) + 1
	local lo = math.floor(rank)
	local frac = rank - lo
	if lo >= #nums then
		return nums[#nums]
	end
	return nums[lo] + frac * (nums[lo + 1] - nums[lo])
end)
FUNCTIONS["QUARTILE.INC"] = FUNCTIONS["QUARTILE"]
register({ "MODE", "MODE.SNGL" }, function(args, ctx)
	local nums = collect_numbers(args, ctx)
	local counts, best, bestc = {}, nil, 0
	for _, n in ipairs(nums) do
		counts[n] = (counts[n] or 0) + 1
		if counts[n] > bestc then
			bestc = counts[n]
			best = n
		end
	end
	if bestc < 2 then
		return ERR.NA
	end
	return best
end)
register("GEOMEAN", function(args, ctx)
	local nums = collect_numbers(args, ctx)
	if #nums == 0 then
		return ERR.NUM
	end
	local p = 1
	for _, n in ipairs(nums) do
		if n <= 0 then
			return ERR.NUM
		end
		p *= n
	end
	return p ^ (1 / #nums)
end)
register("DEVSQ", function(args, ctx)
	local nums = collect_numbers(args, ctx)
	local m = mean_of(nums)
	local s = 0
	for _, n in ipairs(nums) do
		s += (n - m) ^ 2
	end
	return s
end)
register("AVEDEV", function(args, ctx)
	local nums = collect_numbers(args, ctx)
	if #nums == 0 then
		return ERR.NUM
	end
	local m = mean_of(nums)
	local s = 0
	for _, n in ipairs(nums) do
		s += math.abs(n - m)
	end
	return s / #nums
end)

-- ---- *IFS aggregations ------------------------------------------------------

local function ifs_matches(args, ctx, critStart)
	local ranges, preds = {}, {}
	local i = critStart
	while i + 1 <= #args do
		ranges[#ranges + 1] = range_values(args[i], ctx)
		preds[#preds + 1] = make_criterion(as_scalar(args[i + 1], ctx))
		i += 2
	end
	if #ranges == 0 then
		return {}
	end
	local matched = {}
	for idx = 1, #ranges[1] do
		local ok = true
		for k = 1, #ranges do
			local v = ranges[k][idx]
			if is_blank(v) or not preds[k](v) then
				ok = false
				break
			end
		end
		if ok then
			matched[#matched + 1] = idx
		end
	end
	return matched
end

register("SUMIFS", function(args, ctx)
	local srange = range_values(args[1], ctx)
	local s = 0
	for _, idx in ipairs(ifs_matches(args, ctx, 2)) do
		if type(srange[idx]) == "number" then
			s += srange[idx]
		end
	end
	return s
end)
register("COUNTIFS", function(args, ctx)
	return #ifs_matches(args, ctx, 1)
end)
register("AVERAGEIFS", function(args, ctx)
	local srange = range_values(args[1], ctx)
	local s, n = 0, 0
	for _, idx in ipairs(ifs_matches(args, ctx, 2)) do
		if type(srange[idx]) == "number" then
			s += srange[idx]
			n += 1
		end
	end
	if n == 0 then
		return ERR.DIV0
	end
	return s / n
end)
register("MAXIFS", function(args, ctx)
	local srange = range_values(args[1], ctx)
	local m, any = nil, false
	for _, idx in ipairs(ifs_matches(args, ctx, 2)) do
		if type(srange[idx]) == "number" then
			if not any or srange[idx] > m then
				m = srange[idx]
			end
			any = true
		end
	end
	return any and m or 0
end)
register("MINIFS", function(args, ctx)
	local srange = range_values(args[1], ctx)
	local m, any = nil, false
	for _, idx in ipairs(ifs_matches(args, ctx, 2)) do
		if type(srange[idx]) == "number" then
			if not any or srange[idx] < m then
				m = srange[idx]
			end
			any = true
		end
	end
	return any and m or 0
end)

-- ---- math / trig ------------------------------------------------------------

register("PI", function()
	return math.pi
end)
local function reg_math1(name, f, guard)
	register(name, function(args, ctx)
		local n = arg_number(args[1], ctx)
		if is_error(n) then
			return n
		end
		if guard and not guard(n) then
			return ERR.NUM
		end
		return f(n)
	end)
end
reg_math1("SIN", math.sin)
reg_math1("COS", math.cos)
reg_math1("TAN", math.tan)
reg_math1("ASIN", math.asin, function(n)
	return n >= -1 and n <= 1
end)
reg_math1("ACOS", math.acos, function(n)
	return n >= -1 and n <= 1
end)
reg_math1("ATAN", math.atan)
reg_math1("SINH", function(n)
	return (math.exp(n) - math.exp(-n)) / 2
end)
reg_math1("COSH", function(n)
	return (math.exp(n) + math.exp(-n)) / 2
end)
reg_math1("TANH", function(n)
	local a, b = math.exp(n), math.exp(-n)
	return (a - b) / (a + b)
end)
reg_math1("RADIANS", function(n)
	return n * math.pi / 180
end)
reg_math1("DEGREES", function(n)
	return n * 180 / math.pi
end)
reg_math1("SQRTPI", function(n)
	return math.sqrt(n * math.pi)
end, function(n)
	return n >= 0
end)
register("ATAN2", function(args, ctx)
	local x, y = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(x) then
		return x
	end
	if is_error(y) then
		return y
	end
	return math.atan2(y, x)
end)
register("EVEN", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	local c = math.ceil(math.abs(n) / 2) * 2
	return n < 0 and -c or c
end)
register("ODD", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	local a = math.abs(n)
	local c = math.ceil((a + 1) / 2) * 2 - 1
	if c < a then
		c += 2
	end
	return n < 0 and -c or c
end)
register("MROUND", function(args, ctx)
	local n, m = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(n) then
		return n
	end
	if is_error(m) then
		return m
	end
	if m == 0 then
		return 0
	end
	return math.floor(n / m + 0.5) * m
end)
register("QUOTIENT", function(args, ctx)
	local a, b = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	if b == 0 then
		return ERR.DIV0
	end
	local q = a / b
	return q >= 0 and math.floor(q) or math.ceil(q)
end)
register("SUMSQ", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	local s = 0
	for _, n in ipairs(nums) do
		s += n * n
	end
	return s
end)
local function fact(n)
	if n < 0 then
		return ERR.NUM
	end
	local r = 1
	for i = 2, math.floor(n) do
		r *= i
	end
	return r
end
register("FACT", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return fact(n)
end)
register("COMBIN", function(args, ctx)
	local n, k = arg_int(args[1], ctx), arg_int(args[2], ctx)
	if is_error(n) then
		return n
	end
	if is_error(k) then
		return k
	end
	if k < 0 or k > n then
		return ERR.NUM
	end
	local r = 1
	for i = 1, k do
		r = r * (n - i + 1) / i
	end
	return math.floor(r + 0.5)
end)
register("PERMUT", function(args, ctx)
	local n, k = arg_int(args[1], ctx), arg_int(args[2], ctx)
	if is_error(n) then
		return n
	end
	if is_error(k) then
		return k
	end
	if k < 0 or k > n then
		return ERR.NUM
	end
	local r = 1
	for i = 0, k - 1 do
		r *= (n - i)
	end
	return r
end)
local function gcd2(a, b)
	a, b = math.abs(a), math.abs(b)
	while b ~= 0 do
		a, b = b, a % b
	end
	return a
end
register("GCD", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	local g = 0
	for _, n in ipairs(nums) do
		g = gcd2(g, math.floor(n))
	end
	return g
end)
register("LCM", function(args, ctx)
	local nums, err = collect_numbers(args, ctx)
	if err then
		return err
	end
	local l = 1
	for _, n in ipairs(nums) do
		n = math.floor(n)
		if n == 0 then
			return 0
		end
		l = math.abs(l * n) / gcd2(l, n)
	end
	return l
end)
register("RAND", function(args, ctx)
	return (ctx.rand or math.random)()
end)
register("RANDBETWEEN", function(args, ctx)
	local a, b = arg_int(args[1], ctx), arg_int(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	local r = (ctx.rand or math.random)()
	return a + math.floor(r * (b - a + 1))
end)
register({ "CEILING.MATH" }, function(args, ctx)
	local n = arg_number(args[1], ctx)
	local sig = args[2] and arg_number(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if is_error(sig) then
		return sig
	end
	if sig == 0 then
		return 0
	end
	return math.ceil(n / math.abs(sig)) * math.abs(sig)
end)
register({ "FLOOR.MATH" }, function(args, ctx)
	local n = arg_number(args[1], ctx)
	local sig = args[2] and arg_number(args[2], ctx) or 1
	if is_error(n) then
		return n
	end
	if is_error(sig) then
		return sig
	end
	if sig == 0 then
		return 0
	end
	return math.floor(n / math.abs(sig)) * math.abs(sig)
end)

-- ---- text (more) ------------------------------------------------------------

register("CHAR", function(args, ctx)
	local n = arg_int(args[1], ctx)
	if is_error(n) then
		return n
	end
	if n < 1 or n > 255 then
		return ERR.VALUE
	end
	return string.char(n)
end)
register("CODE", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	if #s == 0 then
		return ERR.VALUE
	end
	return string.byte(s, 1)
end)
register({ "UNICHAR" }, function(args, ctx)
	local n = arg_int(args[1], ctx)
	if is_error(n) then
		return n
	end
	if n < 1 then
		return ERR.VALUE
	end
	return utf8.char(n)
end)
register({ "UNICODE" }, function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	if #s == 0 then
		return ERR.VALUE
	end
	return (utf8.codepoint(s, 1))
end)
register("CLEAN", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	return (s:gsub("[%z\1-\31]", ""))
end)
register("T", function(args, ctx)
	local v = as_scalar(args[1], ctx)
	if is_error(v) then
		return v
	end
	return type(v) == "string" and v or ""
end, { errorAware = true })
register("REPLACE", function(args, ctx)
	local s = arg_string(args[1], ctx)
	local start = arg_int(args[2], ctx)
	local len = arg_int(args[3], ctx)
	local new = arg_string(args[4], ctx)
	if is_error(s) then
		return s
	end
	if is_error(start) then
		return start
	end
	if is_error(len) then
		return len
	end
	if is_error(new) then
		return new
	end
	if start < 1 then
		return ERR.VALUE
	end
	return s:sub(1, start - 1) .. new .. s:sub(start + len)
end)
register("FIXED", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	local d = args[2] and arg_int(args[2], ctx) or 2
	if is_error(d) then
		return d
	end
	local noCommas = args[3] ~= nil and to_boolean(as_scalar(args[3], ctx)) == true
	local s = string.format("%." .. math.max(0, d) .. "f", n)
	if not noCommas then
		local intpart, rest = s:match("^(%-?%d+)(.*)$")
		local sign = ""
		if intpart:sub(1, 1) == "-" then
			sign = "-"
			intpart = intpart:sub(2)
		end
		local withCommas = intpart:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
		s = sign .. withCommas .. rest
	end
	return s
end)
register({ "NUMBERVALUE" }, function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local n = tonumber((s:gsub(",", "")))
	if n == nil then
		return ERR.VALUE
	end
	return n
end)

-- ---- information (more) -----------------------------------------------------

register("ISEVEN", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return (math.floor(n) % 2) == 0
end)
register("ISODD", function(args, ctx)
	local n = arg_number(args[1], ctx)
	if is_error(n) then
		return n
	end
	return (math.floor(n) % 2) ~= 0
end)
register("ISREF", function(args, ctx)
	return is_ref(args[1])
end, { errorAware = true })
register({ "ERROR.TYPE" }, function(args, ctx)
	local v = as_scalar(args[1], ctx)
	if not is_error(v) then
		return ERR.NA
	end
	local map = {
		["#NULL!"] = 1,
		["#DIV/0!"] = 2,
		["#VALUE!"] = 3,
		["#REF!"] = 4,
		["#NAME?"] = 5,
		["#NUM!"] = 6,
		["#N/A"] = 7,
	}
	return map[v.code] or ERR.NA
end, { errorAware = true })

-- ---- lookup / reference (more) ----------------------------------------------

register("OFFSET", function(args, ctx)
	local base = args[1]
	if not is_ref(base) then
		return ERR.REF
	end
	local rows, cols = arg_int(args[2], ctx), arg_int(args[3], ctx)
	if is_error(rows) then
		return rows
	end
	if is_error(cols) then
		return cols
	end
	local sheet, c1, r1, c2, r2
	if base.__ref == "cell" then
		sheet, c1, r1, c2, r2 = base.sheet, base.col, base.row, base.col, base.row
	else
		sheet, c1, r1, c2, r2 = base.sheet, base.c1, base.r1, base.c2, base.r2
	end
	local h = args[4] and arg_int(args[4], ctx) or (r2 - r1 + 1)
	local w = args[5] and arg_int(args[5], ctx) or (c2 - c1 + 1)
	if is_error(h) then
		return h
	end
	if is_error(w) then
		return w
	end
	local nr1, nc1 = r1 + rows, c1 + cols
	if h == 1 and w == 1 then
		return { __ref = "cell", sheet = sheet, col = nc1, row = nr1 }
	end
	return { __ref = "range", sheet = sheet, c1 = nc1, r1 = nr1, c2 = nc1 + w - 1, r2 = nr1 + h - 1 }
end, { errorAware = true })

register("INDIRECT", function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local ast = calc.parse(s)
	if ast and (ast.kind == "ref" or ast.kind == "range") then
		return ast.ref
	end
	return ERR.REF
end, { errorAware = true })

register("ROW", function(args, ctx)
	if #args == 0 then
		return ctx.currentRow or ERR.VALUE
	end
	local r = args[1]
	if is_ref(r) then
		return r.__ref == "cell" and r.row or r.r1
	end
	return ERR.VALUE
end, { errorAware = true })
register("COLUMN", function(args, ctx)
	if #args == 0 then
		return ctx.currentCol or ERR.VALUE
	end
	local r = args[1]
	if is_ref(r) then
		return r.__ref == "cell" and r.col or r.c1
	end
	return ERR.VALUE
end, { errorAware = true })

register("ADDRESS", function(args, ctx)
	local row, col = arg_int(args[1], ctx), arg_int(args[2], ctx)
	if is_error(row) then
		return row
	end
	if is_error(col) then
		return col
	end
	local absnum = args[3] and arg_int(args[3], ctx) or 1
	local rowAbs = (absnum == 1 or absnum == 3)
	local colAbs = (absnum == 1 or absnum == 2)
	return (colAbs and "$" or "") .. num_to_col(col) .. (rowAbs and "$" or "") .. tostring(row)
end)

register("LOOKUP", function(args, ctx)
	local key = as_scalar(args[1], ctx)
	if is_error(key) then
		return key
	end
	local vec = range_values(args[2], ctx)
	local resVec = args[3] and range_values(args[3], ctx) or vec
	-- approximate: largest value ≤ key in a sorted vector
	local best
	for i, v in ipairs(vec) do
		if type(v) == type(key) and v <= key then
			best = i
		end
	end
	if not best then
		return ERR.NA
	end
	return resVec[best]
end)

register("XLOOKUP", function(args, ctx)
	local key = as_scalar(args[1], ctx)
	if is_error(key) then
		return key
	end
	local lookupVec = range_values(args[2], ctx)
	local returnVec = range_values(args[3], ctx)
	local function eq(a, b)
		if type(a) == "string" and type(b) == "string" then
			return a:upper() == b:upper()
		end
		return a == b
	end
	for i, v in ipairs(lookupVec) do
		if eq(v, key) then
			return returnVec[i]
		end
	end
	if args[4] ~= nil then
		return as_scalar(args[4], ctx)
	end -- if_not_found
	return ERR.NA
end)

register("TRANSPOSE", function(args, ctx)
	local arr = as_array(args[1], ctx)
	local data = {}
	for c = 1, arr.cols do
		local rowd = {}
		for r = 1, arr.rows do
			rowd[#rowd + 1] = arr.data[r][c]
		end
		data[#data + 1] = rowd
	end
	return mkarray(data)
end, { errorAware = true })

-- ---- dynamic arrays (spill into neighbouring cells via the host) ------------

register("SEQUENCE", function(args, ctx)
	local rows = arg_int(args[1], ctx)
	if is_error(rows) then
		return rows
	end
	local cols = args[2] and arg_int(args[2], ctx) or 1
	if is_error(cols) then
		return cols
	end
	local start = args[3] and arg_number(args[3], ctx) or 1
	if is_error(start) then
		return start
	end
	local step = args[4] and arg_number(args[4], ctx) or 1
	if is_error(step) then
		return step
	end
	if rows < 1 or cols < 1 then
		return ERR.VALUE
	end
	local data, v = {}, start
	for r = 1, rows do
		local rowd = {}
		for c = 1, cols do
			rowd[c] = v
			v += step
		end
		data[r] = rowd
	end
	return mkarray(data)
end, { errorAware = true })

local function norm_cmp(v)
	return is_blank(v) and "" or v
end
local function cmp_lt(a, b)
	a, b = norm_cmp(a), norm_cmp(b)
	local ta, tb = type(a), type(b)
	if ta == tb then
		if ta == "string" then
			return a:upper() < b:upper()
		end
		if ta == "boolean" then
			return (a and 1 or 0) < (b and 1 or 0)
		end
		return a < b
	end
	return (TYPE_ORDER[ta] or 0) < (TYPE_ORDER[tb] or 0)
end

register("UNIQUE", function(args, ctx)
	local arr = as_array(args[1], ctx)
	local seen, out = {}, {}
	for r = 1, arr.rows do
		local parts = {}
		for _, v in ipairs(arr.data[r]) do
			parts[#parts + 1] = type(v) .. "\2" .. tostring(norm_cmp(v))
		end
		local key = table.concat(parts, "\1")
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = arr.data[r]
		end
	end
	return mkarray(out)
end, { errorAware = true })

register("SORT", function(args, ctx)
	local arr = as_array(args[1], ctx)
	local idx = args[2] and arg_int(args[2], ctx) or 1
	if is_error(idx) then
		return idx
	end
	local order = args[3] and arg_number(args[3], ctx) or 1
	if is_error(order) then
		return order
	end
	local rows = {}
	for r = 1, arr.rows do
		rows[#rows + 1] = arr.data[r]
	end
	table.sort(rows, function(a, b)
		if order < 0 then
			return cmp_lt(b[idx], a[idx])
		end
		return cmp_lt(a[idx], b[idx])
	end)
	return mkarray(rows)
end, { errorAware = true })

register("FILTER", function(args, ctx)
	local arr = as_array(args[1], ctx)
	local mask = as_array(args[2], ctx)
	local out = {}
	for r = 1, arr.rows do
		local m = mask.data[math.min(r, mask.rows)][1]
		if is_error(m) then
			return m
		end
		if to_boolean(m) == true then
			out[#out + 1] = arr.data[r]
		end
	end
	if #out == 0 then
		if args[3] ~= nil then
			return as_scalar(args[3], ctx)
		end
		return ERR.NA
	end
	return mkarray(out)
end, { errorAware = true })

-- ---- date / time (more) -----------------------------------------------------

register("TIME", function(args, ctx)
	local h, m, s = arg_int(args[1], ctx), arg_int(args[2], ctx), arg_int(args[3], ctx)
	if is_error(h) then
		return h
	end
	if is_error(m) then
		return m
	end
	if is_error(s) then
		return s
	end
	return ((h * 3600 + m * 60 + s) % 86400) / 86400
end)
register("HOUR", function(args, ctx)
	local v = arg_number(args[1], ctx)
	if is_error(v) then
		return v
	end
	return math.floor((v - math.floor(v)) * 24 + 1e-9) % 24
end)
register("MINUTE", function(args, ctx)
	local v = arg_number(args[1], ctx)
	if is_error(v) then
		return v
	end
	return math.floor((v * 1440) + 1e-9) % 60
end)
register("SECOND", function(args, ctx)
	local v = arg_number(args[1], ctx)
	if is_error(v) then
		return v
	end
	return math.floor((v * 86400) + 0.5) % 60
end)
register("DAYS", function(args, ctx)
	local a, b = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	return math.floor(a) - math.floor(b)
end)
register("DATEDIF", function(args, ctx)
	local s1, s2 = arg_number(args[1], ctx), arg_number(args[2], ctx)
	local unit = arg_string(args[3], ctx)
	if is_error(s1) then
		return s1
	end
	if is_error(s2) then
		return s2
	end
	if is_error(unit) then
		return unit
	end
	local y1, m1, d1 = serial_to_ymd(s1)
	local y2, m2, d2 = serial_to_ymd(s2)
	unit = unit:upper()
	if unit == "D" then
		return math.floor(s2) - math.floor(s1)
	end
	if unit == "Y" then
		local y = y2 - y1
		if m2 < m1 or (m2 == m1 and d2 < d1) then
			y -= 1
		end
		return y
	end
	if unit == "M" then
		local m = (y2 - y1) * 12 + (m2 - m1)
		if d2 < d1 then
			m -= 1
		end
		return m
	end
	if unit == "MD" then
		return d2 - d1
	end
	if unit == "YM" then
		local m = (m2 - m1) % 12
		if d2 < d1 then
			m = (m - 1) % 12
		end
		return m
	end
	return ERR.NUM
end)
register("WEEKNUM", function(args, ctx)
	local s = arg_int(args[1], ctx)
	if is_error(s) then
		return s
	end
	local y = serial_to_ymd(s)
	local jan1 = days_from_civil(y, 1, 1) - EXCEL_EPOCH
	local jan1wd = (jan1 + EXCEL_EPOCH + 4) % 7 -- 0=Sun
	return math.floor((s - jan1 + jan1wd) / 7) + 1
end)
register("YEARFRAC", function(args, ctx)
	local s1, s2 = arg_number(args[1], ctx), arg_number(args[2], ctx)
	if is_error(s1) then
		return s1
	end
	if is_error(s2) then
		return s2
	end
	-- basis 0 (US 30/360) approximation via actual/365 by default-friendly actual/actual-ish
	return math.abs(s2 - s1) / 365
end)
register({ "DATEVALUE" }, function(args, ctx)
	local s = arg_string(args[1], ctx)
	if is_error(s) then
		return s
	end
	local y, m, d = s:match("^(%d+)%-(%d+)%-(%d+)")
	if not y then
		m, d, y = s:match("^(%d+)/(%d+)/(%d+)")
	end
	if not y then
		return ERR.VALUE
	end
	return days_from_civil(tonumber(y), tonumber(m), tonumber(d)) - EXCEL_EPOCH
end)

-- ---- financial --------------------------------------------------------------

local function fin_num(args, idx, ctx, default)
	if args[idx] == nil then
		return default
	end
	return arg_number(args[idx], ctx)
end
register("PMT", function(args, ctx)
	local rate = arg_number(args[1], ctx)
	local nper = arg_number(args[2], ctx)
	local pv = arg_number(args[3], ctx)
	local fv = fin_num(args, 4, ctx, 0)
	local typ = fin_num(args, 5, ctx, 0)
	for _, e in ipairs({ rate, nper, pv, fv, typ }) do
		if is_error(e) then
			return e
		end
	end
	if rate == 0 then
		return -(pv + fv) / nper
	end
	local p = (1 + rate) ^ nper
	return -(pv * p + fv) * rate / ((p - 1) * (1 + rate * typ))
end)
register("FV", function(args, ctx)
	local rate = arg_number(args[1], ctx)
	local nper = arg_number(args[2], ctx)
	local pmt = arg_number(args[3], ctx)
	local pv = fin_num(args, 4, ctx, 0)
	local typ = fin_num(args, 5, ctx, 0)
	for _, e in ipairs({ rate, nper, pmt, pv, typ }) do
		if is_error(e) then
			return e
		end
	end
	if rate == 0 then
		return -(pv + pmt * nper)
	end
	local p = (1 + rate) ^ nper
	return -(pv * p + pmt * (1 + rate * typ) * (p - 1) / rate)
end)
register("PV", function(args, ctx)
	local rate = arg_number(args[1], ctx)
	local nper = arg_number(args[2], ctx)
	local pmt = arg_number(args[3], ctx)
	local fv = fin_num(args, 4, ctx, 0)
	local typ = fin_num(args, 5, ctx, 0)
	for _, e in ipairs({ rate, nper, pmt, fv, typ }) do
		if is_error(e) then
			return e
		end
	end
	if rate == 0 then
		return -(fv + pmt * nper)
	end
	local p = (1 + rate) ^ nper
	return -(fv + pmt * (1 + rate * typ) * (p - 1) / rate) / p
end)
register("NPER", function(args, ctx)
	local rate = arg_number(args[1], ctx)
	local pmt = arg_number(args[2], ctx)
	local pv = arg_number(args[3], ctx)
	local fv = fin_num(args, 4, ctx, 0)
	local typ = fin_num(args, 5, ctx, 0)
	for _, e in ipairs({ rate, pmt, pv, fv, typ }) do
		if is_error(e) then
			return e
		end
	end
	if rate == 0 then
		return -(pv + fv) / pmt
	end
	local num = pmt * (1 + rate * typ) - fv * rate
	local den = pv * rate + pmt * (1 + rate * typ)
	if num / den <= 0 then
		return ERR.NUM
	end
	return math.log(num / den) / math.log(1 + rate)
end)
register("NPV", function(args, ctx)
	local rate = arg_number(args[1], ctx)
	if is_error(rate) then
		return rate
	end
	local nums = collect_numbers({ table.unpack(args, 2) }, ctx)
	local total, i = 0, 1
	for _, v in ipairs(nums) do
		total += v / (1 + rate) ^ i
		i += 1
	end
	return total
end)
register("IRR", function(args, ctx)
	local nums = collect_numbers({ args[1] }, ctx)
	if #nums < 2 then
		return ERR.NUM
	end
	local function npv(rate)
		local t = 0
		for i, v in ipairs(nums) do
			t += v / (1 + rate) ^ (i - 1)
		end
		return t
	end
	-- bisection between -0.9999 and a large rate
	local lo, hi = -0.9999, 10
	local flo, fhi = npv(lo), npv(hi)
	if flo * fhi > 0 then
		return ERR.NUM
	end
	for _ = 1, 200 do
		local mid = (lo + hi) / 2
		local fm = npv(mid)
		if math.abs(fm) < 1e-9 then
			return mid
		end
		if flo * fm < 0 then
			hi, fhi = mid, fm
		else
			lo, flo = mid, fm
		end
	end
	return (lo + hi) / 2
end)
register("SLN", function(args, ctx)
	local cost, salvage, life =
		arg_number(args[1], ctx), arg_number(args[2], ctx), arg_number(args[3], ctx)
	for _, e in ipairs({ cost, salvage, life }) do
		if is_error(e) then
			return e
		end
	end
	if life == 0 then
		return ERR.DIV0
	end
	return (cost - salvage) / life
end)
register("SYD", function(args, ctx)
	local cost, salvage, life, per =
		arg_number(args[1], ctx),
		arg_number(args[2], ctx),
		arg_number(args[3], ctx),
		arg_number(args[4], ctx)
	for _, e in ipairs({ cost, salvage, life, per }) do
		if is_error(e) then
			return e
		end
	end
	return (cost - salvage) * (life - per + 1) * 2 / (life * (life + 1))
end)
register("RATE", function(args, ctx)
	local nper = arg_number(args[1], ctx)
	local pmt = arg_number(args[2], ctx)
	local pv = arg_number(args[3], ctx)
	local fv = fin_num(args, 4, ctx, 0)
	local typ = fin_num(args, 5, ctx, 0)
	local guess = fin_num(args, 6, ctx, 0.1)
	for _, e in ipairs({ nper, pmt, pv, fv, typ, guess }) do
		if is_error(e) then
			return e
		end
	end
	local function f(rate)
		if rate == 0 then
			return pv + pmt * nper + fv
		end
		local p = (1 + rate) ^ nper
		return pv * p + pmt * (1 + rate * typ) * (p - 1) / rate + fv
	end
	local rate = guess
	for _ = 1, 100 do
		local fr = f(rate)
		local d = (f(rate + 1e-6) - fr) / 1e-6
		if d == 0 then
			break
		end
		local nr = rate - fr / d
		if math.abs(nr - rate) < 1e-10 then
			return nr
		end
		rate = nr
	end
	return rate
end)

-- ---- engineering (base conversions + bitwise) -------------------------------

local function to_base(n, base, places)
	n = math.floor(n)
	local neg = n < 0
	local digits = "0123456789ABCDEF"
	if neg then
		-- 10-digit two's complement (Excel's representation for DEC2BIN/OCT/HEX)
		n = base ^ 10 + n
	end
	if n == 0 then
		return "0"
	end
	local s = ""
	while n > 0 do
		local r = n % base
		s = digits:sub(r + 1, r + 1) .. s
		n = math.floor(n / base)
	end
	if places and not neg and #s < places then
		s = string.rep("0", places - #s) .. s
	end
	return s
end
local function from_base(s, base)
	s = s:upper()
	local neg = (
		#s == 10
		and tonumber(s:sub(1, 1), base)
		and tonumber(s:sub(1, 1), base) >= base / 2
	)
	local n = tonumber(s, base)
	if n == nil then
		return ERR.NUM
	end
	if neg then
		n = n - base ^ 10
	end
	return n
end
local function reg_dec2(name, base)
	register(name, function(args, ctx)
		local n = arg_number(args[1], ctx)
		if is_error(n) then
			return n
		end
		local places = args[2] and arg_int(args[2], ctx) or nil
		return to_base(n, base, places)
	end)
end
reg_dec2("DEC2BIN", 2)
reg_dec2("DEC2OCT", 8)
reg_dec2("DEC2HEX", 16)
local function reg_x2dec(name, base)
	register(name, function(args, ctx)
		local s = arg_string(args[1], ctx)
		if is_error(s) then
			return s
		end
		return from_base(s, base)
	end)
end
reg_x2dec("BIN2DEC", 2)
reg_x2dec("OCT2DEC", 8)
reg_x2dec("HEX2DEC", 16)
local function reg_bit(name, f)
	register(name, function(args, ctx)
		local a, b = arg_int(args[1], ctx), arg_int(args[2], ctx)
		if is_error(a) then
			return a
		end
		if is_error(b) then
			return b
		end
		return f(a, b)
	end)
end
reg_bit("BITAND", function(a, b)
	return bit32.band(a, b)
end)
reg_bit("BITOR", function(a, b)
	return bit32.bor(a, b)
end)
reg_bit("BITXOR", function(a, b)
	return bit32.bxor(a, b)
end)
reg_bit("BITLSHIFT", function(a, b)
	return bit32.lshift(a, b)
end)
reg_bit("BITRSHIFT", function(a, b)
	return bit32.rshift(a, b)
end)
register("DELTA", function(args, ctx)
	local a = arg_number(args[1], ctx)
	local b = args[2] and arg_number(args[2], ctx) or 0
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	return a == b and 1 or 0
end)
register("GESTEP", function(args, ctx)
	local a = arg_number(args[1], ctx)
	local b = args[2] and arg_number(args[2], ctx) or 0
	if is_error(a) then
		return a
	end
	if is_error(b) then
		return b
	end
	return a >= b and 1 or 0
end)

-- ===========================================================================
-- Host conversions (CellValue ⇄ engine Value) + result wrapping
-- ===========================================================================

-- An engine Value → the value a host should store. Errors → { error = code };
-- numbers/strings/booleans pass through; blank → nil; arrays → top-left scalar.
function calc.unwrap(v)
	if is_error(v) then
		return { error = v.code }
	end
	if is_blank(v) then
		return nil
	end
	if is_array(v) then
		local first = v.data[1] and v.data[1][1]
		return calc.unwrap(first == nil and BLANK or first)
	end
	if is_ref(v) then
		return nil
	end -- a bare reference result is unusual; host derefs
	return v
end

return calc
