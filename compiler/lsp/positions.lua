-- Loc <-> LSP position conversions (P0).
-- Lexer Loc is 1-based {line, col} in BYTES (see compiler/lexer.lua).
-- LSP positions are 0-based {line, character} in units of the negotiated
-- positionEncoding ("utf-8" preferred, "utf-16" fallback).
-- All conversions live here so byte/UTF-16 math is paid once.

local M = {}

--- Byte indices where each 1-based line starts.
--- @param src string
--- @return integer[] starts
function M.line_starts(src)
    local starts = { 1 }
    for k = 1, #src do
        if src:sub(k, k) == "\n" then
            starts[#starts + 1] = k + 1
        end
    end
    return starts
end

--- Count UTF-16 code units in a byte string (BMP chars count 1,
--- supplementary-plane chars encoded in 4 UTF-8 bytes count 2).
--- @param s string UTF-8 bytes
--- @return integer units
function M.utf16_len(s)
    local n = 0
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local w
        if b < 0x80 then
            w = 1
        elseif b < 0xE0 then
            w = 2
        elseif b < 0xF0 then
            w = 3
        else
            w = 4
        end
        if w == 4 then
            n = n + 2
        else
            n = n + 1
        end
        i = i + w
    end
    return n
end

--- Convert a 1-based byte column to a 0-based LSP character.
--- @param line_text string source line bytes (no newline)
--- @param byte_col integer 1-based byte column
--- @param encoding string "utf-8"|"utf-16"
--- @return integer char 0-based LSP character
function M.byte_col_to_char(line_text, byte_col, encoding)
    local prefix = line_text:sub(1, math.max(byte_col - 1, 0))
    if encoding == "utf-16" then
        return M.utf16_len(prefix)
    end
    return #prefix
end

--- Convert a 0-based LSP character back to a 1-based byte column.
--- @param line_text string source line bytes (no newline)
--- @param char integer 0-based LSP character
--- @param encoding string "utf-8"|"utf-16"
--- @return integer byte_col 1-based byte column
function M.char_to_byte_col(line_text, char, encoding)
    if encoding ~= "utf-16" then
        return char + 1
    end
    local units = 0
    local i = 1
    while i <= #line_text + 1 do
        if units >= char then
            return i
        end
        if i > #line_text then
            return i
        end
        local b = string.byte(line_text, i)
        local w
        if b < 0x80 then
            w = 1
        elseif b < 0xE0 then
            w = 2
        elseif b < 0xF0 then
            w = 3
        else
            w = 4
        end
        units = units + (w == 4 and 2 or 1)
        i = i + w
    end
    return #line_text + 1
end

--- Source text of 1-based line n (no trailing newline), or "" if unknown.
--- @param src string
--- @param starts integer[] from line_starts
--- @param n integer 1-based line
--- @return string
function M.line_text(src, starts, n)
    local s = starts[n]
    if s == nil then
        return ""
    end
    local e = (starts[n + 1] or (#src + 2)) - 2
    if e < s then
        return ""
    end
    return src:sub(s, e)
end

--- Convert a compiler Loc to an LSP Range.
--- Loc end positions are exclusive; single-point locs collapse.
--- @param loc table {line, col, end_line, end_col}
--- @param src string full source (for UTF-16 measurement)
--- @param starts integer[]|nil precomputed line starts
--- @param encoding string|nil "utf-8" (default) or "utf-16"
--- @return table range {start={line,character}, ["end"]={line,character}}
function M.loc_to_range(loc, src, starts, encoding)
    encoding = encoding or "utf-8"
    starts = starts or M.line_starts(src)
    local sl = math.max((loc.line or 1) - 1, 0)
    local el = math.max((loc.end_line or loc.line or 1) - 1, 0)
    local stext = M.line_text(src, starts, sl + 1)
    local etext = M.line_text(src, starts, el + 1)
    return {
        start = {
            line = sl,
            character = M.byte_col_to_char(stext, loc.col or 1, encoding),
        },
        ["end"] = {
            line = el,
            character = M.byte_col_to_char(etext, loc.end_col or loc.col or 1, encoding),
        },
    }
end

--- Convert an LSP Position to a 1-based {line, col-bytes} pair.
--- @param src string
--- @param starts integer[]|nil
--- @param pos table {line, character}
--- @param encoding string|nil
--- @return integer line 1-based
--- @return integer byte_col 1-based byte column
function M.position_to_loc(src, starts, pos, encoding)
    encoding = encoding or "utf-8"
    starts = starts or M.line_starts(src)
    local line = (pos.line or 0) + 1
    local text = M.line_text(src, starts, line)
    return line, M.char_to_byte_col(text, pos.character or 0, encoding)
end

return M
