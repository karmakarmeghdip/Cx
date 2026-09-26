-- Minimal JSON encode/decode for the LSP stdio transport (P0).
-- Pure LuaJIT, no dependencies. Objects are tables with string keys;
-- arrays are tables with 1..n integer keys. `M.null` is the JSON null
-- sentinel (decoded null; encoded as `null`).
-- Module pattern: `local M = {}` returning a table (AGENTS.md section 2).

local M = {}

--- JSON null sentinel.
M.null = setmetatable({}, {
    __tostring = function() return "null" end,
})

--- Escape a Lua string as a JSON string.
--- @param s string
--- @return string
local function esc(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        if c == '\b' then return '\\b' end
        if c == '\f' then return '\\f' end
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end

--- True when `t` encodes as a JSON array (all keys are 1..n).
--- @param t table
--- @return boolean
local function is_array(t)
    local n = #t
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
            return false
        end
        count = count + 1
    end
    return count == n
end

--- Encode a Lua value as JSON.
--- @param v any
--- @return string
function M.encode(v)
    local tv = type(v)
    if v == M.null then
        return "null"
    end
    if tv == "nil" then
        return "null"
    end
    if tv == "boolean" then
        return v and "true" or "false"
    end
    if tv == "number" then
        assert(v == v and v ~= math.huge and v ~= -math.huge, "json: cannot encode NaN/inf")
        return tostring(v)
    end
    if tv == "string" then
        return esc(v)
    end
    if tv == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do
                parts[#parts + 1] = M.encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            assert(type(k) == "string", "json: object keys must be strings")
            parts[#parts + 1] = esc(k) .. ":" .. M.encode(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("json: cannot encode " .. tv, 0)
end

--- Decoder state over one input string.
---@class JsonReader
---@field s string input
---@field i integer cursor (1-based)

--- Skip JSON whitespace.
--- @param r JsonReader
local function skip_ws(r)
    while r.i <= #r.s do
        local c = r.s:sub(r.i, r.i)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then
            break
        end
        r.i = r.i + 1
    end
end

local decode_value -- forward declaration

--- Decode a JSON string literal at the cursor.
--- @param r JsonReader
--- @return string
local function decode_string(r)
    assert(r.s:sub(r.i, r.i) == '"', "json: expected string")
    r.i = r.i + 1
    local out = {}
    while r.i <= #r.s do
        local c = r.s:sub(r.i, r.i)
        if c == '"' then
            r.i = r.i + 1
            return table.concat(out)
        end
        if c == '\\' then
            local e = r.s:sub(r.i + 1, r.i + 1)
            if e == '"' or e == '\\' or e == '/' then
                out[#out + 1] = e
                r.i = r.i + 2
            elseif e == 'n' then
                out[#out + 1] = '\n'
                r.i = r.i + 2
            elseif e == 'r' then
                out[#out + 1] = '\r'
                r.i = r.i + 2
            elseif e == 't' then
                out[#out + 1] = '\t'
                r.i = r.i + 2
            elseif e == 'b' then
                out[#out + 1] = '\b'
                r.i = r.i + 2
            elseif e == 'f' then
                out[#out + 1] = '\f'
                r.i = r.i + 2
            elseif e == 'u' then
                local hex = r.s:sub(r.i + 2, r.i + 5)
                local cp = tonumber(hex, 16)
                assert(cp ~= nil, "json: bad \\u escape")
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(
                        0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
                else
                    out[#out + 1] = string.char(
                        0xE0 + math.floor(cp / 0x1000),
                        0x80 + (math.floor(cp / 0x40) % 0x40),
                        0x80 + (cp % 0x40))
                end
                r.i = r.i + 6
            else
                error("json: bad escape \\" .. e, 0)
            end
        else
            out[#out + 1] = c
            r.i = r.i + 1
        end
    end
    error("json: unterminated string", 0)
end

--- Decode a JSON number at the cursor.
--- @param r JsonReader
--- @return number
local function decode_number(r)
    local m = r.s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', r.i)
    assert(m ~= nil and #m > 0, "json: bad number")
    r.i = r.i + #m
    local n = tonumber(m)
    assert(n ~= nil, "json: bad number")
    return n
end

--- Decode a JSON array at the cursor.
--- @param r JsonReader
--- @return table
local function decode_array(r)
    assert(r.s:sub(r.i, r.i) == '[', "json: expected [")
    r.i = r.i + 1
    local out = {}
    skip_ws(r)
    if r.s:sub(r.i, r.i) == ']' then
        r.i = r.i + 1
        return out
    end
    while true do
        out[#out + 1] = decode_value(r)
        skip_ws(r)
        local c = r.s:sub(r.i, r.i)
        if c == ',' then
            r.i = r.i + 1
        elseif c == ']' then
            r.i = r.i + 1
            return out
        else
            error("json: expected , or ] in array", 0)
        end
    end
end

--- Decode a JSON object at the cursor.
--- @param r JsonReader
--- @return table
local function decode_object(r)
    assert(r.s:sub(r.i, r.i) == '{', "json: expected {")
    r.i = r.i + 1
    local out = {}
    skip_ws(r)
    if r.s:sub(r.i, r.i) == '}' then
        r.i = r.i + 1
        return out
    end
    while true do
        skip_ws(r)
        local k = decode_string(r)
        skip_ws(r)
        assert(r.s:sub(r.i, r.i) == ':', "json: expected : in object")
        r.i = r.i + 1
        out[k] = decode_value(r)
        skip_ws(r)
        local c = r.s:sub(r.i, r.i)
        if c == ',' then
            r.i = r.i + 1
        elseif c == '}' then
            r.i = r.i + 1
            return out
        else
            error("json: expected , or } in object", 0)
        end
    end
end

--- Decode one JSON value at the cursor.
--- @param r JsonReader
--- @return any
decode_value = function(r)
    skip_ws(r)
    local c = r.s:sub(r.i, r.i)
    if c == '"' then
        return decode_string(r)
    end
    if c == '{' then
        return decode_object(r)
    end
    if c == '[' then
        return decode_array(r)
    end
    if r.s:sub(r.i, r.i + 3) == "true" then
        r.i = r.i + 4
        return true
    end
    if r.s:sub(r.i, r.i + 4) == "false" then
        r.i = r.i + 5
        return false
    end
    if r.s:sub(r.i, r.i + 3) == "null" then
        r.i = r.i + 4
        return M.null
    end
    return decode_number(r)
end

--- Decode a full JSON document (trailing whitespace allowed).
--- @param s string
--- @return any
function M.decode(s)
    assert(type(s) == "string", "json.decode: string required")
    local r = { s = s, i = 1 }
    local v = decode_value(r)
    skip_ws(r)
    assert(r.i > #s, "json: trailing content after document")
    return v
end

return M
