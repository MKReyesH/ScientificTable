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
local table_bibliographies = {}

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

-- Fetches the BibTeX records once per document, in batches.
local function fetch_inspire_entries(keys)

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

    return entries_by_key
end

local function render_bibliography(keys, entries, meta, table_index)
    local records = {}
    local citations = pandoc.Inlines{}
    for _, key in ipairs(keys) do
        if entries[key] then
            table.insert(records, entries[key])
            citations:insert(pandoc.Cite({pandoc.Str("@" .. key)}, {pandoc.Citation(key, "NormalCitation")}))
            citations:insert(pandoc.Space())
        end
    end
    if #records == 0 then return {} end

    local references = pandoc.read(table.concat(records, "\n\n"), "bibtex").meta.references
    local table_doc = pandoc.utils.citeproc(pandoc.Pandoc({}, {
        references = references,
        nocite = citations,
        csl = meta.csl,
        lang = meta.lang,
        ["link-bibliography"] = meta["link-bibliography"]
    }))

    local bibliography = table_doc.blocks[1]
    if not bibliography then return {} end
    bibliography.identifier = ""
    for _, entry in ipairs(bibliography.content) do
        local key = entry.identifier:match("^ref%-(.+)$")
        if key then
            entry.attributes["data-cite-key"] = key
            entry.identifier = "dynamic-table-ref-" .. table_index .. "-" .. key
        end
    end

    local heading = pandoc.Header(4, "Table references")
    local wrapper = pandoc.Div({heading, bibliography}, pandoc.Attr("", {"dynamic-table-refs"}, {style = "display:none;"}))
    -- Keep the table bibliography opaque to Quarto's document citation and appendix filters.
    return pandoc.RawBlock("html", pandoc.write(pandoc.Pandoc({wrapper}), "html"))
end

-- Parses one CSV record per line, supporting quoted fields and escaped quotes
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
    if line:sub(-1) == "," then
        table.insert(res, "")
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

    -- A quoted header can contain commas. Remove its entire option before splitting tags.
    local first, last, header = body:find('header%s*=%s*(%b"")%s*,?')
    if not first then
        first, last, header = body:find("header%s*=%s*(%b'')%s*,?")
    end
    if not first then
        first, last, header = body:find("header%s*=%s*([^,]*),?")
    end
    if first then
        local title = U.strip_quotes(U.trim(header))
        if title ~= "" then rule.header = title end
        body = body:sub(1, first - 1) .. body:sub(last + 1)
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
        elseif tag == "latexnum" then
            rule.latexnum = true
            rule.latex = true
            rule.type = "number"
        elseif tag == "inspire" then
            rule.inspire = true
            rule.type = "string"
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
    local inspire_fields = {}
    local final_columns_meta = {}
    for j = 1, #headers do
        local idx = j - 1
        local col_rule = meta_by_index[idx] or { index = idx }

        if not col_rule.type and DEFAULTS.auto_type then
            col_rule.type = auto_detect_column_type(rows, j)
        end

        has_table_math = has_table_math or col_rule.latex == true

        if col_rule.inspire then
            table.insert(inspire_fields, "col_" .. tostring(idx))
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

    local table_block = pandoc.RawBlock("html", html)
    if #inspire_fields == 0 then return table_block end

    local keys, seen = {}, {}
    for _, row in ipairs(rows) do
        for _, field in ipairs(inspire_fields) do
            for _, key in ipairs(split_citation_keys(row[field])) do
                if not seen[key] then
                    seen[key] = true
                    table.insert(keys, key)
                    register_inspire_key(key)
                end
            end
        end
    end
    if #keys == 0 then return table_block end

    table.insert(table_bibliographies, keys)
    local marker = pandoc.Div({}, pandoc.Attr("", {}, {["dynamic-table-bibliography"] = tostring(#table_bibliographies)}))
    return {table_block, marker}
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

-- Pandoc filter hook for literal table configuration blocks.
function CodeBlock(el)
    if not el.classes:includes("dynamic-table") then return nil end
    local opts = default_table_options()
    local columns_meta = {}

    for k, v in pairs(el.attributes) do
        apply_table_option(opts, k, v)
    end

    for _, line in ipairs(U.literal_lines(el.text)) do
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

-- Renders each table bibliography independently, then injects the shared client assets.
function Pandoc(doc)
    if #table_bibliographies > 0 then
        local entries = fetch_inspire_entries(inspire_keys)
        local meta = doc.meta
        doc = doc:walk({
            Div = function(div)
                local index = tonumber(div.attributes["dynamic-table-bibliography"])
                if index and table_bibliographies[index] then
                    return render_bibliography(table_bibliographies[index], entries, meta, index)
                end
            end
        })
        table_bibliographies = {}
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
