-- =============================================================================
-- Dynamic CSV Table Pre-Renderer & Hydrator (Pandoc Lua Filter)
-- Parses CSVs at build time and conditionally injects Simple-DataTables assets.
-- =============================================================================

local has_dynamic_table = false

-- HTML escaping helper
local function html_escape(str)
    if not str then return "" end
    str = string.gsub(str, "&", "&amp;")
    str = string.gsub(str, "<", "&lt;")
    str = string.gsub(str, ">", "&gt;")
    str = string.gsub(str, '"', "&quot;")
    return str
end

-- CSV parser supporting quoted strings and escaped quotes
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

-- Safe CSV file loader (handles relative document paths)
local function open_csv_file(src)
    local file = io.open(src, "r")
    if file then return file end
    
    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then
            file = io.open(doc_dir .. src, "r")
            if file then return file end
        end
    end
    return nil
end

-- Element-level hook: Transforms ::: {.dynamic-table src="..."} into static HTML
function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end

    local src = el.attributes["src"] or el.attributes["file"]
    if not src or src == "" then return nil end

    local file = open_csv_file(src)
    if not file then return nil end

    local lines = {}
    for line in file:lines() do
        line = string.gsub(line, "\r$", "")
        if line:match("%S") then table.insert(lines, line) end
    end
    file:close()

    if #lines == 0 then return nil end

    -- Signal that this page requires client-side dynamic table JS/CSS
    has_dynamic_table = true

    local headers = parse_csv_line(lines[1])
    local html = {}
    table.insert(html, '<div class="dynamic-table-wrapper">')
    table.insert(html, '  <table class="dynamic-table-target table table-striped table-hover">')
    table.insert(html, '    <thead><tr>')
    for _, h in ipairs(headers) do
        table.insert(html, '        <th>' .. html_escape(h:match("^%s*(.-)%s*$")) .. '</th>')
    end
    table.insert(html, '    </tr></thead><tbody>')

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
                    -- Store numeric float in data-order attribute for exact sorting
                    table.insert(html, string.format('        <td data-order="%s">%s</td>', tostring(num), display_txt))
                else
                    table.insert(html, string.format('        <td>%s</td>', display_txt))
                end
            end
        end
        table.insert(html, '      </tr>')
    end

    table.insert(html, '    </tbody></table></div>')
    return pandoc.RawBlock('html', table.concat(html, "\n"))
end

-- Document-level hook: Appends scripts ONCE at the end of pages containing tables
function Pandoc(doc)
    if has_dynamic_table then
        local assets_html = [[
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css">
<script src="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js"></script>
<script>
  document.addEventListener("DOMContentLoaded", function () {
    const tables = document.querySelectorAll("table.dynamic-table-target");
    tables.forEach((table) => {
      new simpleDatatables.DataTable(table, {
        searchable: true,
        sortable: true,
        perPage: 15,
        labels: {
          placeholder: "Search table...",
          perPage: "{select} entries per page",
          noRows: "No entries found",
          info: "Showing {start} to {end} of {rows} entries",
        }
      });
    });
  });
</script>
]]
        table.insert(doc.blocks, pandoc.RawBlock('html', assets_html))
        
        -- Reset state so subsequent pages without tables do not load the scripts
        has_dynamic_table = false
    end
    return doc
end