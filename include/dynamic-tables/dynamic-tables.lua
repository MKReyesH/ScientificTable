-- =============================================================================
-- Dynamic Tables Lua Filter
-- =============================================================================

local TAG = "dynamic-tables.lua"
local SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""

local U
do
    local orig_path = package.path
    package.path = SCRIPT_DIR .. "../?.lua;" .. orig_path
    local ok, mod = pcall(require, "shared-utils")
    package.path = orig_path
    if not ok then
        error(string.format("[%s] Error: Required module 'shared-utils.lua' not found: %s", TAG, tostring(mod)))
    end
    U = mod
end

local DEFAULTS = {
    searchable = false,
    sortable   = true,
    per_page   = 15,
    auto_type  = true
}

local has_dynamic_table = false
local has_table_math = false
local inspire_keys = {}
local inspire_keys_seen = {}

-- Percent-encodes URL query strings
local function url_encode(str)
    return (str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Splits comma- or semicolon-separated citation keys and strips leading '@'
local function split_citation_keys(raw)
    local keys = {}
    if not raw or raw == "" then return keys end
    for token in raw:gmatch("[^,;]+") do
        local key = U.trim(token):gsub("^@", "")
        if key ~= "" then table.insert(keys, key) end
    end
    return keys
end

-- Records unique INSPIRE citation keys in initial CSV row order
local function register_inspire_key(key)
    if key ~= "" and not inspire_keys_seen[key] then
        inspire_keys_seen[key] = true
        table.insert(inspire_keys, key)
    end
end

-- Indexes BibTeX entries by citation key using balanced-brace matching
local function index_bibtex_entries(raw_bib, entries_by_key)
    local pos, len = 1, #raw_bib
    while pos <= len do
        local start_idx, end_idx = raw_bib:find("@[%w_%-]+%s*%b{}", pos)
        if not start_idx then break end

        local entry_text = U.trim(raw_bib:sub(start_idx, end_idx))
        local entry_key = entry_text:match("^@[%w_%-]+%s*{%s*([^,%s]+)%s*,")
        if entry_key then
            entries_by_key[entry_key] = entry_text
        end
        pos = end_idx + 1
    end
end

-- Fetches BibTeX records from INSPIRE-HEP in batches and writes an ordered temporary .bib file
local function write_temp_inspire_bibtex(keys)
    if #keys == 0 then return nil end

    local entries_by_key = {}
    local batch_size = 50

    -- Batch API requests to respect INSPIRE-HEP rate limits
    for i = 1, #keys, batch_size do
        local query_parts = {}
        local upper = math.min(i + batch_size - 1, #keys)
        for j = i, upper do
            table.insert(query_parts, 'texkey:"' .. keys[j] .. '"')
        end
        local query = table.concat(query_parts, " OR ")
        local api_url = "https://inspirehep.net/api/literature?q=" .. url_encode(query) .. "&size=" .. tostring(batch_size) .. "&format=bibtex"

        local ok, _, body = pcall(pandoc.mediabag.fetch, api_url)
        if ok and body and body:match("@%w+%s*{") then
            index_bibtex_entries(body, entries_by_key)
        else
            io.stderr:write(string.format("[%s] Warning: Failed to fetch INSPIRE BibTeX batch (%d-%d).\n", TAG, i, upper))
        end
    end

    -- Reorder entries to match initial CSV row sequence
    local ordered_entries = {}
    for _, key in ipairs(keys) do
        if entries_by_key[key] then
            table.insert(ordered_entries, entries_by_key[key])
        end
    end
    if #ordered_entries == 0 then return nil end

    local raw_tmp = os.tmpname()
    os.remove(raw_tmp)
    local tmp_bib = raw_tmp .. ".bib"

    local out = io.open(tmp_bib, "w")
    if not out then
        io.stderr:write(string.format("[%s] Warning: Could not create temporary BibTeX file '%s'.\n", TAG, tmp_bib))
        return nil
    end

    out:write(table.concat(ordered_entries, "\n\n") .. "\n")
    out:close()
    return tmp_bib
end

-- Appends the temporary .bib file path to document bibliography metadata
local function append_meta_bibliography(meta, bib_path)
    local list = pandoc.MetaList({})
    local existing = {}

    local function add_entry(val)
        local str = U.trim(pandoc.utils.stringify(val))
        if str ~= "" and not existing[str] then
            existing[str] = true
            list:insert(pandoc.MetaString(str))
        end
    end

    if meta.bibliography then
        if meta.bibliography.t == "MetaList" then
            for _, item in ipairs(meta.bibliography) do add_entry(item) end
        else
            add_entry(meta.bibliography)
        end
    end

    add_entry(bib_path)
    meta.bibliography = list
end

-- Parses an RFC-4180 CSV line supporting quoted fields and escaped quotes
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
            table.insert(res, U.trim(val))
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local comma_pos = line:find(",", pos)
            if not comma_pos then
                table.insert(res, U.trim(line:sub(pos)))
                break
            else
                table.insert(res, U.trim(line:sub(pos, comma_pos - 1)))
                pos = comma_pos + 1
            end
        end
    end
    return res
end

-- Infers numeric vs string column type from non-empty cell values
local function auto_detect_column_type(rows, col_index)
    local has_numeric = false
    for _, r in ipairs(rows) do
        local val = U.trim(r["col_" .. tostring(col_index - 1)] or "")
        if val ~= "" then
            if not tonumber(val) then return "string" end
            has_numeric = true
        end
    end
    return has_numeric and "number" or "string"
end

-- Parses per-column directives (header, unit conversions, formatting tags)
local function parse_column_rule(line)
    local col_idx = tonumber(line:match("^col%a*%s+(%d+)"))
    if not col_idx then return nil end
    local body = U.trim(line:match(":%s*(.*)$") or "")
    local rule = { index = col_idx }

    -- Extract quoted or unquoted header title before comma-splitting flags
    local raw_header = body:match('header%s*=%s*(%b"")')
        or body:match("header%s*=%s*(%b'')")
        or body:match('header%s*=%s*(.-)%s*,')
        or body:match('header%s*=%s*(.*)$')
    if raw_header then
        local clean_hdr = U.trim(raw_header):gsub('^["\'“]+', ''):gsub('["\'”]+$', '')
        if clean_hdr ~= "" then rule.header = clean_hdr end
        body = body:gsub('header%s*=%s*%b""%s*,?', '', 1)
                   :gsub("header%s*=%s*%b''%s*,?", '', 1)
                   :gsub('header%s*=%s*.-,', '', 1)
                   :gsub('header%s*=%s*.*$', '', 1)
    end

    -- Extract unit conversion map
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
        tag = U.trim(tag)
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
        elseif tag == "latex" then
            rule.latex = true
            has_table_math = true
        elseif tag == "latexnum" then
            rule.latexnum = true
            rule.latex = true
            rule.type = "number"
            has_table_math = true
        elseif tag == "inspire" then
            rule.inspire = true
            rule.type = "string"
        end
    end

    -- Normalize math delimiters based on whether header LaTeX rendering is active
    if rule.header then
        if U.has_math(rule.header) then
            has_table_math = true
        end
        if rule.latex then
            rule.header = rule.header:gsub("%$([^%$]+)%$", "\\(%1\\)")
        else
            rule.header = rule.header:gsub("\\%((.-)\\%)", "$%1$")
        end
    end

    return rule
end

-- Creates default table configuration options
local function default_table_options()
    return {
        src        = nil,
        searchable = tostring(DEFAULTS.searchable),
        per_page   = tostring(DEFAULTS.per_page),
        sortable   = tostring(DEFAULTS.sortable)
    }
end

-- Applies a key-value option to a table options object
local function apply_table_option(opts, key, val)
    key = U.trim(key):lower()
    val = U.trim(val)
    if val == "" then return end
    if key == "src" then opts.src = val
    elseif key == "searchable" then opts.searchable = val
    elseif key == "per-page" then opts.per_page = val
    elseif key == "sortable" then opts.sortable = val end
end

-- Builds the HTML mount container and optional bibliography placeholder for a CSV table
local function render_table(opts, columns_meta)
    local file = U.open_data_file(opts.src, SCRIPT_DIR)
    if not file then
        error(string.format("[%s] Error: Cannot open CSV file at '%s'. Check file path.", TAG, opts.src))
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
    for _, h in ipairs(raw_headers) do table.insert(headers, U.trim(h)) end

    local rows = {}
    for i = 2, #lines do
        local raw_row = parse_csv_line(lines[i])
        local row_obj = {}
        for j = 1, #headers do
            row_obj["col_" .. tostring(j - 1)] = U.trim(raw_row[j] or "")
        end
        table.insert(rows, row_obj)
    end

    local meta_by_index = {}
    for _, m in ipairs(columns_meta or {}) do meta_by_index[m.index] = m end

    -- Resolve column types and collect INSPIRE citation keys
    local has_inspire = false
    local final_columns_meta = {}
    for j = 1, #headers do
        local idx = j - 1
        local col_rule = meta_by_index[idx] or { index = idx }

        if not col_rule.type and DEFAULTS.auto_type then
            col_rule.type = auto_detect_column_type(rows, j)
        end

        if col_rule.inspire then
            has_inspire = true
            local field = "col_" .. tostring(idx)
            for _, r in ipairs(rows) do
                for _, key in ipairs(split_citation_keys(r[field])) do
                    register_inspire_key(key)
                end
            end
        end

        table.insert(final_columns_meta, col_rule)
    end

    local html = string.format(
        '<div class="tabulator-container-wrap" data-headers="%s" data-rows="%s" data-columns="%s" data-searchable="%s" data-perpage="%s" data-sortable="%s"></div>',
        U.html_escape(pandoc.json.encode(headers)),
        U.html_escape(pandoc.json.encode(rows)),
        U.html_escape(pandoc.json.encode(final_columns_meta)),
        U.html_escape(opts.searchable),
        U.html_escape(opts.per_page),
        U.html_escape(opts.sortable)
    )

    if has_inspire then
        html = html .. '\n<div class="dynamic-table-refs" style="display:none;"></div>'
    end

    return pandoc.RawBlock("html", html)
end

-- Pandoc filter hook for shorthand '!dynamic-table: path.csv' paragraphs
function Para(p)
    local txt = U.trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    if not src then return nil end
    local opts = default_table_options()
    opts.src = U.trim(src)
    return render_table(opts, {})
end

-- Pandoc filter hook for '::: {.dynamic-table}' fenced divs
function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end
    local opts = default_table_options()
    local columns_meta = {}

    for k, v in pairs(el.attributes) do
        apply_table_option(opts, k, v)
    end

    for _, line in ipairs(U.extract_lines_from_div(el)) do
        if not line:match("^#") then
            local key, val = line:match("^([%w_%-]+):%s*(.*)$")
            if key and val then
                apply_table_option(opts, key, val)
            elseif line:lower():match("^col") then
                local col_rule = parse_column_rule(line)
                if col_rule then table.insert(columns_meta, col_rule) end
            end
        end
    end

    return (opts.src and opts.src ~= "") and render_table(opts, columns_meta) or nil
end

-- Pandoc document hook: generates temporary INSPIRE BibTeX metadata and injects client assets
function Pandoc(doc)
    if #inspire_keys > 0 then
        local tmp_bib = write_temp_inspire_bibtex(inspire_keys)
        if tmp_bib then
            append_meta_bibliography(doc.meta, tmp_bib)

            -- Preserve existing nocite entries before appending table citation keys
            local nocite_inlines = {}
            if doc.meta.nocite then
                if doc.meta.nocite.t == "MetaInlines" then
                    for _, item in ipairs(doc.meta.nocite) do
                        table.insert(nocite_inlines, item)
                    end
                elseif doc.meta.nocite.t == "MetaBlocks" then
                    for _, blk in ipairs(doc.meta.nocite) do
                        if blk.content then
                            for _, item in ipairs(blk.content) do
                                table.insert(nocite_inlines, item)
                            end
                        end
                    end
                else
                    local parsed = pandoc.read(pandoc.utils.stringify(doc.meta.nocite), "markdown")
                    for _, blk in ipairs(parsed.blocks) do
                        if blk.content then
                            for _, item in ipairs(blk.content) do
                                table.insert(nocite_inlines, item)
                            end
                        end
                    end
                end
            end

            for _, key in ipairs(inspire_keys) do
                if #nocite_inlines > 0 then
                    table.insert(nocite_inlines, pandoc.Space())
                end
                table.insert(nocite_inlines, pandoc.Cite({ pandoc.Str("@" .. key) }, { pandoc.Citation(key, "NormalCitation") }))
            end
            doc.meta.nocite = pandoc.MetaInlines(nocite_inlines)
        end

        inspire_keys = {}
        inspire_keys_seen = {}
    end

    if has_dynamic_table then
        if has_table_math then
            U.ensure_quarto_math(doc)
        end
        U.inject_widget(doc, "dynamic-tables", SCRIPT_DIR, {
            head = '<link rel="stylesheet" href="https://unpkg.com/tabulator-tables@5.5.2/dist/css/tabulator.min.css">',
            body_prefix = '<script src="https://unpkg.com/tabulator-tables@5.5.2/dist/js/tabulator.min.js"></script>'
        })
        has_dynamic_table = false
        has_table_math = false
    end
    return doc
end