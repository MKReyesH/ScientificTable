-- =============================================================================
-- Dynamic CSV Tables Pandoc Lua Filter
-- =============================================================================

-- Default configuration
local DEFAULTS = {
    searchable = true,
    sortable   = true,
    per_page   = 15,
    auto_type  = true
}

-- Filter path mappings
local PATHS = {
    filter_rel   = "lua/dynamic%-tables%.lua",
    template_rel = "include/dynamic-tables.html"
}

local has_dynamic_table = false
local cached_assets_html = nil

local SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""

-- Load template HTML assets
local function load_assets_html()
    if cached_assets_html then return cached_assets_html end
    
    local html_path = PANDOC_SCRIPT_FILE:gsub(PATHS.filter_rel .. "$", PATHS.template_rel)
    local file = io.open(html_path, "r")
    if not file then
        error("[dynamic-tables.lua] Error: Cannot open template at '" .. html_path .. "'. Check file path.")
    end
    
    cached_assets_html = file:read("*a")
    file:close()
    return cached_assets_html
end

-- String utilities
local function trim(s) 
    return s and s:match("^%s*(.-)%s*$") or "" 
end

local function html_escape(s)
    return s and (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) or ""
end

-- CSV line parser
local function parse_csv_line(line)
    local res, pos, len = {}, 1, #line
    while pos <= len do
        if line:sub(pos, pos) == '"' then
            local val = ""
            pos = pos + 1
            while pos <= len do
                local c = line:sub(pos, pos)
                if c == '"' then
                    if line:sub(pos + 1, pos + 1) == '"' then val = val .. '"'; pos = pos + 2
                    else pos = pos + 1; break end
                else val = val .. c; pos = pos + 1 end
            end
            table.insert(res, trim(val))
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local comma_pos = line:find(",", pos)
            if not comma_pos then 
                table.insert(res, trim(line:sub(pos)))
                break
            else 
                table.insert(res, trim(line:sub(pos, comma_pos - 1)))
                pos = comma_pos + 1 
            end
        end
    end
    return res
end

-- File resolution helper
local function open_csv_file(src)
    local file = io.open(src, "r")
    if file then return file end

    if SCRIPT_DIR ~= "" then
        file = io.open(SCRIPT_DIR .. "../" .. src, "r")
        if file then return file end
    end

    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then
            file = io.open(doc_dir .. src, "r")
            if file then return file end
        end
    end

    return nil
end

-- Column data type detection
local function auto_detect_column_type(rows, col_index)
    local has_numeric = false
    for _, r in ipairs(rows) do
        local val = trim(r["col_" .. tostring(col_index - 1)] or "")
        if val ~= "" then
            local num = tonumber(val)
            if not num then return "string" end
            has_numeric = true
        end
    end
    return has_numeric and "number" or "string"
end

-- AST text extraction preserving Math elements ($...$) recursively
local function stringify_inline_with_math(inline)
    if not inline then return "" end
    
    if inline.t == "Math" then
        if inline.mathtype == "DisplayMath" or inline.mathtype == pandoc.DisplayMath then
            return "$$" .. inline.text .. "$$"
        else
            return "$" .. inline.text .. "$"
        end
    elseif inline.t == "Space" then
        return " "
    elseif inline.t == "SoftBreak" or inline.t == "LineBreak" then
        return "\n"
    elseif inline.t == "Str" then
        return inline.text
    elseif inline.t == "Quoted" then
        local q_char = (inline.quotetype == "SingleQuote" or inline.quotetype == pandoc.SingleQuote) and "'" or '"'
        local inner = {}
        for _, child in ipairs(inline.content or {}) do
            table.insert(inner, stringify_inline_with_math(child))
        end
        return q_char .. table.concat(inner) .. q_char
    elseif inline.c or inline.content then
        local children = inline.content or inline.c
        if type(children) == "table" then
            local res = {}
            for _, child in ipairs(children) do
                table.insert(res, stringify_inline_with_math(child))
            end
            return table.concat(res)
        end
    end
    
    return pandoc.utils.stringify(inline)
end

local function extract_lines_from_div(el)
    local lines = {}
    for _, block in ipairs(el.content) do
        if block.content then
            local current = {}
            for _, inline in ipairs(block.content) do
                if inline.t == "SoftBreak" or inline.t == "LineBreak" then
                    local l = trim(table.concat(current))
                    if l ~= "" then table.insert(lines, l) end
                    current = {}
                else
                    table.insert(current, stringify_inline_with_math(inline))
                end
            end
            local final = trim(table.concat(current))
            if final ~= "" then table.insert(lines, final) end
        end
    end
    return lines
end

-- Column rule parser
local function parse_column_rule(line)
    local col_idx = tonumber(line:match("^col%a*%s+(%d+)"))
    if not col_idx then return nil end
    local body = trim(line:match(":%s*(.*)$") or "")
    local rule = { index = col_idx }

    -- Normalize smart/curly quotes produced by Pandoc typography parsing
    body = body:gsub("“", '"'):gsub("”", '"'):gsub("’", "'"):gsub("‘", "'")

    -- Parse custom header label: header="..." or header='...' or unquoted
    local header_val = body:match('header%s*=%s*["\'](.-)["\']') or body:match('header%s*=%s*([^,]+)')
    if header_val then
        rule.header = trim(header_val)
        body = body:gsub('header%s*=%s*["\'](.-)["\']', ""):gsub('header%s*=%s*[^,]+', "")
    end

    local units_str = body:match("units%((.-)%)")
    if units_str then
        local map, units = {}, {}
        for pair in units_str:gmatch("[^,]+") do
            local u, f = pair:match("^%s*(.-)%s*:%s*([%d%.eE%-%+]+)%s*$")
            if u and f then map[u] = tonumber(f); table.insert(units, u) end
        end
        rule.units = units
        rule.map = map
        rule.type = "number"
        body = body:gsub("units%((.-)%)", "")
    end

    for tag in body:gmatch("[^,]+") do
        tag = trim(tag)
        if tag ~= "" then
            if tag == "unsortable" then
                rule.sortable = false
            elseif tag == "sortable" then
                rule.sortable = true
            elseif tag == "dropdown" then
                rule.dropdown = true
            elseif tag == "string" then
                rule.type = "string"
            elseif tag == "number" then
                rule.type = "number"
            end
        end
    end

    return rule
end

-- Main table renderer
local function render_table(src, searchable, per_page, sortable, columns_meta)
    local file = open_csv_file(src)
    if not file then
        error("[dynamic-tables.lua] Error: Cannot open CSV file at '" .. src .. "'. Check file path.")
    end

    local lines = {}
    for line in file:lines() do
        line = line:gsub("\r$", "")
        if line:match("%S") then table.insert(lines, line) end
    end
    file:close()
    if #lines == 0 then return nil end

    has_dynamic_table = true

    local raw_headers = parse_csv_line(lines[1])
    local headers = {}
    for _, h in ipairs(raw_headers) do table.insert(headers, trim(h)) end

    local rows = {}
    for i = 2, #lines do
        local raw_row = parse_csv_line(lines[i])
        local row_obj = {}
        for j = 1, #headers do
            row_obj["col_" .. tostring(j - 1)] = trim(raw_row[j] or "")
        end
        table.insert(rows, row_obj)
    end

    local meta_by_index = {}
    for _, m in ipairs(columns_meta or {}) do meta_by_index[m.index] = m end

    local final_columns_meta = {}
    for j = 1, #headers do
        local idx = j - 1
        local col_rule = meta_by_index[idx] or { index = idx }
        
        if not col_rule.type and DEFAULTS.auto_type then
            col_rule.type = auto_detect_column_type(rows, j)
        end
        
        table.insert(final_columns_meta, col_rule)
    end

    local html = string.format(
        '<div class="tabulator-container-wrap column-page" data-headers="%s" data-rows="%s" data-columns="%s" data-searchable="%s" data-perpage="%s" data-sortable="%s"></div>',
        html_escape(pandoc.json.encode(headers)),
        html_escape(pandoc.json.encode(rows)),
        html_escape(pandoc.json.encode(final_columns_meta)),
        html_escape(searchable or tostring(DEFAULTS.searchable)),
        html_escape(per_page or tostring(DEFAULTS.per_page)),
        html_escape(sortable or tostring(DEFAULTS.sortable))
    )

    return pandoc.RawBlock('html', html)
end

-- Pandoc AST entry points
function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    return src and render_table(trim(src), tostring(DEFAULTS.searchable), tostring(DEFAULTS.per_page), tostring(DEFAULTS.sortable), {}) or nil
end

function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end
    local src = el.attributes["src"]
    local searchable = el.attributes["searchable"] or tostring(DEFAULTS.searchable)
    local per_page   = el.attributes["per-page"] or tostring(DEFAULTS.per_page)
    local sortable   = el.attributes["sortable"] or tostring(DEFAULTS.sortable)
    local columns_meta = {}

    for _, line in ipairs(extract_lines_from_div(el)) do
        if not line:match("^#") then
            local key, val = line:match("^([%w_%-]+):%s*(.*)$")
            if key and val then
                key = key:lower(); val = trim(val)
                if key == "src" then src = val
                elseif key == "searchable" then searchable = val
                elseif key == "per-page" then per_page = val
                elseif key == "sortable" then sortable = val end
            elseif line:lower():match("^col") then
                local col_rule = parse_column_rule(line)
                if col_rule then table.insert(columns_meta, col_rule) end
            end
        end
    end

    return (src and src ~= "") and render_table(src, searchable, per_page, sortable, columns_meta) or nil
end

function Pandoc(doc)
    if has_dynamic_table then
        local assets_html = load_assets_html()
        table.insert(doc.blocks, pandoc.RawBlock('html', assets_html))
        has_dynamic_table = false
    end
    return doc
end