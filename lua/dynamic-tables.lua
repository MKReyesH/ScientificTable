-- =============================================================================
-- Dynamic CSV Table Pre-Renderer (Pandoc Lua Filter)
-- Reads CSV files from disk at build-time and outputs static HTML tables
-- with data-sort attributes for numerical sorting in Simple-DataTables.
-- =============================================================================

local function html_escape(str)
    if not str then return "" end
    str = string.gsub(str, "&", "&amp;")
    str = string.gsub(str, "<", "&lt;")
    str = string.gsub(str, ">", "&gt;")
    str = string.gsub(str, '"', "&quot;")
    return str
end

-- Lightweight CSV line parser supporting quoted fields
local function parse_csv_line(line)
    local res = {}
    local pos = 1
    local len = #line
    while pos <= len do
        local c = string.sub(line, pos, pos)
        if c == '"' then
            local txt = ""
            pos = pos + 1
            while pos <= len do
                local nc = string.sub(line, pos, pos)
                if nc == '"' then
                    if pos < len and string.sub(line, pos+1, pos+1) == '"' then
                        txt = txt .. '"'
                        pos = pos + 2
                    else
                        pos = pos + 1
                        break
                    end
                else
                    txt = txt .. nc
                    pos = pos + 1
                end
            end
            table.insert(res, txt)
            if pos <= len and string.sub(line, pos, pos) == ',' then
                pos = pos + 1
            end
        else
            local comma_pos = string.find(line, ",", pos)
            if not comma_pos then
                table.insert(res, string.sub(line, pos))
                break
            else
                table.insert(res, string.sub(line, pos, comma_pos - 1))
                pos = comma_pos + 1
            end
        end
    end
    return res
end

-- Helper to safely resolve file paths across directory structures
local function open_csv_file(src)
    local file = io.open(src, "r")
    if file then return file end
    
    -- Fallback: resolve relative to document directory
    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then
            file = io.open(doc_dir .. src, "r")
            if file then return file end
        end
    end
    return nil
end

function Div(el)
    -- Target divs with class .dynamic-table
    if not el.classes:includes("dynamic-table") then
        return nil
    end

    local src = el.attributes["src"] or el.attributes["file"]
    if not src or src == "" then
        print("[dynamic-tables.lua] Warning: Missing 'src' attribute in .dynamic-table div")
        return nil
    end

    local file = open_csv_file(src)
    if not file then
        print("[dynamic-tables.lua] Error: Could not open CSV file at '" .. src .. "'")
        return nil
    end

    local lines = {}
    for line in file:lines() do
        line = string.gsub(line, "\r$", "") -- Strip carriage returns
        if line:match("%S") then
            table.insert(lines, line)
        end
    end
    file:close()

    if #lines == 0 then
        return nil
    end

    -- 1. Parse Header Row
    local headers = parse_csv_line(lines[1])
    
    -- 2. Construct Static HTML Structure
    local html = {}
    table.insert(html, '<div class="dynamic-table-wrapper">')
    table.insert(html, '  <table class="dynamic-table-target table table-striped table-hover">')
    table.insert(html, '    <thead>')
    table.insert(html, '      <tr>')
    for _, h in ipairs(headers) do
        local h_text = html_escape(h:match("^%s*(.-)%s*$"))
        table.insert(html, '        <th>' .. h_text .. '</th>')
    end
    table.insert(html, '      </tr>')
    table.insert(html, '    </thead>')
    table.insert(html, '    <tbody>')

    -- 3. Parse Data Rows & Attach data-sort Attributes
    for i = 2, #lines do
        local row = parse_csv_line(lines[i])
        table.insert(html, '      <tr>')
        for j = 1, #headers do
            local cell_raw = row[j] or ""
            local cell_trimmed = cell_raw:match("^%s*(.-)%s*$")
            
            if cell_trimmed == "" then
                table.insert(html, '        <td></td>')
            else
                local num = tonumber(cell_trimmed)
                local display_txt = html_escape(cell_trimmed)
                
                if num then
                    -- Attach calculated numeric float as data-sort for client-side sorting
                    table.insert(html, string.format('        <td data-sort="%s">%s</td>', tostring(num), display_txt))
                else
                    table.insert(html, string.format('        <td>%s</td>', display_txt))
                end
            end
        end
        table.insert(html, '      </tr>')
    end

    table.insert(html, '    </tbody>')
    table.insert(html, '  </table>')
    table.insert(html, '</div>')

    return pandoc.RawBlock('html', table.concat(html, "\n"))
end