-- =============================================================================
-- DYNAMIC CSV TABLE RENDERER & HYDRATOR (Pandoc Lua Filter)
--
-- SYNTAX SPECIFICATION:
-- 1. Quick Syntax:       !dynamic-table: path/to/data.csv
-- 2. Customized Syntax:  ::: {.dynamic-table}
--                        src: path/to/data.csv
--                        per-page: 15
--                        searchable: true|false
--                        sortable: true|false
--                        column 0: header="ID", unsortable
--                        column 1: header="Category", dropdown, string
--                        column 3: sortable, number
--                        column 4: header=$E_{\text{LIV}}^{(1)}$, units(Planck units: 1, eV: 1.22e28), latexnum
--                        :::
-- =============================================================================

local has_dynamic_table = false

local function trim(s) return s and s:match("^%s*(.-)%s*$") or "" end

local function html_escape(s)
    return s and (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) or ""
end

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
            table.insert(res, val)
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local comma_pos = line:find(",", pos)
            if not comma_pos then table.insert(res, line:sub(pos)); break
            else table.insert(res, line:sub(pos, comma_pos - 1)); pos = comma_pos + 1 end
        end
    end
    return res
end

local function open_csv_file(src)
    local file = io.open(src, "r")
    if file then return file end
    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then return io.open(doc_dir .. src, "r") end
    end
    return nil
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
                else table.insert(current, pandoc.utils.stringify(inline)) end
            end
            local final = trim(table.concat(current))
            if final ~= "" then table.insert(lines, final) end
        end
    end
    return lines
end

local function parse_column_rule(line)
    local col_idx = tonumber(line:match("^col%a*%s+(%d+)"))
    if not col_idx then return nil end
    local body = trim(line:match(":%s*(.*)$") or "")
    local rule = { index = col_idx }

    -- Extract header=... (handles quoted, smart-quoted, or unquoted values)
    local hdr_quoted = body:match('header%s*=%s*(["\'\226\128\156\226\128\158].-["\'\226\128\157\226\128\159])')
    if hdr_quoted then
        rule.header = hdr_quoted
        body = body:gsub('header%s*=%s*["\'\226\128\156\226\128\158].-["\'\226\128\157\226\128\159]', "")
    else
        local hdr_unquoted = body:match('header%s*=%s*([^,]+)')
        if hdr_unquoted then
            rule.header = trim(hdr_unquoted)
            body = body:gsub('header%s*=%s*[^,]+', "")
        end
    end

    -- Extract units(...)
    local units_str = body:match("units%((.-)%)")
    if units_str then
        local map, units = {}, {}
        for pair in units_str:gmatch("[^,]+") do
            local u, f = pair:match("^%s*(.-)%s*:%s*([%d%.eE%-%+]+)%s*$")
            if u and f then map[u] = tonumber(f); table.insert(units, u) end
        end
        rule.units = units
        rule.map = map
        body = body:gsub("units%((.-)%)", "")
    end

    -- Extract column tags
    for tag in body:gmatch("[^,]+") do
        tag = trim(tag:lower())
        if tag == "unsortable" then rule.sortable = false
        elseif tag == "sortable" then rule.sortable = true
        elseif tag == "dropdown" then rule.dropdown = true
        elseif tag == "string" or tag == "text" then rule.type = "string"
        elseif tag == "number" or tag == "numeric" then rule.type = "number"
        elseif tag == "latexnum" or tag == "latex-number" or tag == "latex_number" then rule.type = "latexnum" end
    end

    return rule
end

local function format_header_html(hdr)
    if not hdr then return nil end
    hdr = trim(hdr)
    
    -- Strip ASCII quotes (" and ')
    hdr = hdr:gsub('^["\']', ''):gsub('["\']$', '')
    -- Strip UTF-8 smart double quotes (“ and ”)
    hdr = hdr:gsub('^\226\128\156', ''):gsub('\226\128\157$', '')
    -- Strip UTF-8 smart single quotes (‘ and ’)
    hdr = hdr:gsub('^\226\128\158', ''):gsub('\226\128\159$', '')
    hdr = trim(hdr)

    -- Check if string is wrapped in $...$ or \(...\)
    local math_content = hdr:match("^%$(.*)%$") or hdr:match("^\\%((.*)\\%)$")
    if math_content then
        return string.format('<span class="math inline">\\(%s\\)</span>', math_content)
    end

    -- If Pandoc stringify stripped $ delimiters, but string contains TeX syntax (\, _, ^)
    if hdr:match("\\[%a]+") or hdr:match("[_%^]") then
        return string.format('<span class="math inline">\\(%s\\)</span>', hdr)
    end

    return html_escape(hdr)
end

local function render_table(src, searchable, per_page, sortable, columns_meta)
    local file = open_csv_file(src)
    if not file then return nil end
    local lines = {}
    for line in file:lines() do
        line = line:gsub("\r$", "")
        if line:match("%S") then table.insert(lines, line) end
    end
    file:close()
    if #lines == 0 then return nil end

    has_dynamic_table = true
    local headers = parse_csv_line(lines[1])
    local html = { '<div class="dynamic-table-wrapper">' }

    table.insert(html, string.format(
        '  <table class="dynamic-table-target table table-striped table-hover" data-searchable="%s" data-per-page="%s" data-sortable="%s" data-columns="%s">',
        html_escape(searchable or "true"), html_escape(per_page or "15"), html_escape(sortable or "true"), html_escape(pandoc.json.encode(columns_meta or {}))
    ))
    table.insert(html, '    <thead><tr>')
    for j, h in ipairs(headers) do
        local col_override = nil
        if columns_meta then
            for _, col in ipairs(columns_meta) do
                if col.index == (j - 1) and col.header then
                    col_override = format_header_html(col.header)
                    break
                end
            end
        end
        local header_content = col_override or html_escape(trim(h))
        table.insert(html, '        <th>' .. header_content .. '</th>')
    end
    table.insert(html, '    </tr></thead><tbody>')

    for i = 2, #lines do
        local row = parse_csv_line(lines[i])
        table.insert(html, '      <tr>')
        for j = 1, #headers do
            local cell_trimmed = trim(row[j])
            if cell_trimmed == "" then
                table.insert(html, '        <td></td>')
            else
                local num = tonumber(cell_trimmed)
                local display_txt = html_escape(cell_trimmed)
                if num then table.insert(html, string.format('        <td data-order="%s">%s</td>', tostring(num), display_txt))
                else table.insert(html, string.format('        <td>%s</td>', display_txt)) end
            end
        end
        table.insert(html, '      </tr>')
    end

    table.insert(html, '    </tbody></table></div>')
    return pandoc.RawBlock('html', table.concat(html, "\n"))
end

local function load_client_assets()
    local script_dir = PANDOC_SCRIPT_DIR or "."
    local target_path = script_dir .. "/../include/dynamic-tables.html"
    local file = io.open(target_path, "r")
    if not file then
        file = io.open("include/dynamic-tables.html", "r")
    end
    if file then
        local content = file:read("*a")
        file:close()
        return content
    end
    io.stderr:write("[dynamic-tables] Error: Could not locate include/dynamic-tables.html\n")
    return ""
end

function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    return src and render_table(trim(src), "true", "15", "true", {}) or nil
end

function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end
    local src = el.attributes["src"]
    local searchable, per_page, sortable = "true", "15", "true"
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
        local assets_html = load_client_assets()
        if assets_html ~= "" then
            table.insert(doc.blocks, pandoc.RawBlock('html', assets_html))
        end
        has_dynamic_table = false
    end
    return doc
end