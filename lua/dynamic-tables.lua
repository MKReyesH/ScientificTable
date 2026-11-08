-- =============================================================================
-- DYNAMIC CSV TABLE RENDERER & HYDRATOR (Pandoc Lua Filter)
--
-- SYNTAX SPECIFICATION:
--
-- 1. Quick Syntax (Single-line command with default settings):
--    !dynamic-table: path/to/data.csv
--
--    Defaults applied:
--      - searchable: true
--      - per-page: 15
--      - sortable: true (all columns)
--
-- 2. Customized Syntax (Multiline Div with explicit properties):
--    ::: {.dynamic-table}
--    src: path/to/data.csv
--    searchable: false           -- Optional (default: true)
--    per-page: 25                -- Optional (default: 15)
--    sortable: true              -- Optional (default: true)
--    column 0: unsortable        -- Optional (0-based index)
--    column 3: unsortable
--    :::
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

-- Core Table Renderer
local function render_table(src, searchable, per_page, sortable, unsortable)
    local file = open_csv_file(src)
    if not file then return nil end

    local lines = {}
    for line in file:lines() do
        line = string.gsub(line, "\r$", "")
        if line:match("%S") then table.insert(lines, line) end
    end
    file:close()

    if #lines == 0 then return nil end

    has_dynamic_table = true

    local headers = parse_csv_line(lines[1])
    local html = {}
    table.insert(html, '<div class="dynamic-table-wrapper">')
    
    local table_tag = string.format(
        '  <table class="dynamic-table-target table table-striped table-hover" data-searchable="%s" data-per-page="%s" data-sortable="%s" data-unsortable="%s">',
        html_escape(searchable or "true"),
        html_escape(per_page or "15"),
        html_escape(sortable or "true"),
        html_escape(unsortable or "")
    )
    table.insert(html, table_tag)
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

-- 1. QUICK SYNTAX HANDLER (!dynamic-table: path/to/file.csv)
function Para(p)
    local txt = pandoc.utils.stringify(p):match("^%s*(.-)%s*$")
    local src = txt:match("^%!dynamic%-table:%s*(%S+)")
    if src then
        local raw = render_table(src, "true", "15", "true", "")
        if raw then return raw end
    end
    return nil
end

-- 2. CUSTOMIZED MULTILINE SYNTAX HANDLER (::: {.dynamic-table})
function Div(el)
    if not el.classes:includes("dynamic-table") then
        return nil
    end

    local src = el.attributes["src"]
    local searchable = "true"
    local per_page = "15"
    local sortable = "true"
    local unsortable_tbl = {}

    -- Single-pass strict key-value parsing
    local text_content = pandoc.utils.stringify(el)
    for line in text_content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local key, val = line:match("^([%w_%-]+):%s*(.-)%s*$")
            if key and val then
                if key == "src" then
                    src = val
                elseif key == "searchable" then
                    searchable = val
                elseif key == "per-page" then
                    per_page = val
                elseif key == "sortable" then
                    sortable = val
                end
            elseif line:lower():match("^column") then
                local col_num = line:match("%d+")
                if col_num and line:lower():match("unsortable") then
                    table.insert(unsortable_tbl, col_num)
                end
            end
        end
    end

    if not src or src == "" then return nil end

    local unsortable = table.concat(unsortable_tbl, ",")
    return render_table(src, searchable, per_page, sortable, unsortable)
end

-- DOCUMENT-LEVEL ASSET INJECTION HOOK
function Pandoc(doc)
    if has_dynamic_table then
        local assets_html = [[
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css">
<script src="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js"></script>
<script>
  document.addEventListener("DOMContentLoaded", function () {
    const tables = document.querySelectorAll("table.dynamic-table-target");
    tables.forEach((table) => {
      const searchable = table.dataset.searchable !== "false";
      const sortable = table.dataset.sortable !== "false";
      const perPage = parseInt(table.dataset.perPage || "15", 10);
      
      const columnRules = [];
      if (table.dataset.unsortable && table.dataset.unsortable.trim() !== "") {
        const unsortList = table.dataset.unsortable
          .split(",")
          .map((x) => parseInt(x.trim(), 10))
          .filter((x) => !isNaN(x));
        
        if (unsortList.length > 0) {
          columnRules.push({ select: unsortList, sortable: false });
        }
      }

      new simpleDatatables.DataTable(table, {
        searchable: searchable,
        sortable: sortable,
        perPage: perPage,
        columns: columnRules.length > 0 ? columnRules : undefined,
        labels: {
          placeholder: "Search table...",
          perPage: "entries per page",
          noRows: "No entries found",
          info: "Showing {start} to {end} of {rows} entries",
        }
      });
    });
  });
</script>
]]
        table.insert(doc.blocks, pandoc.RawBlock('html', assets_html))
        
        -- Reset flag for multi-page builds
        has_dynamic_table = false
    end
    return doc
end
