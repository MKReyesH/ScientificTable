-- =============================================================================
-- DYNAMIC CSV TABLE RENDERER & HYDRATOR (Pandoc Lua Filter)
--
-- SYNTAX SPECIFICATION:
--
-- 1. Quick Syntax (Single-line command):
--    !dynamic-table: path/to/data.csv
--
-- 2. Customized Syntax (Multiline Div):
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

-- Client-side library & initialization asset template
local CLIENT_ASSETS_HTML = [[
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

-- -----------------------------------------------------------------------------
-- 1. UTILITY FUNCTIONS
-- -----------------------------------------------------------------------------

local function trim(s)
    return s and s:match("^%s*(.-)%s*$") or ""
end

local function html_escape(str)
    if not str then return "" end
    return (str:gsub("&", "&amp;")
               :gsub("<", "&lt;")
               :gsub(">", "&gt;")
               :gsub('"', "&quot;"))
end

-- Fast CSV tokenizer supporting quoted cells and escaped quotes
local function parse_csv_line(line)
    local res = {}
    local pos = 1
    local len = #line

    while pos <= len do
        if line:sub(pos, pos) == '"' then
            local val = ""
            pos = pos + 1
            while pos <= len do
                local c = line:sub(pos, pos)
                if c == '"' then
                    if line:sub(pos + 1, pos + 1) == '"' then
                        val = val .. '"'
                        pos = pos + 2
                    else
                        pos = pos + 1
                        break
                    end
                else
                    val = val .. c
                    pos = pos + 1
                end
            end
            table.insert(res, val)
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local comma_pos = line:find(",", pos)
            if not comma_pos then
                table.insert(res, line:sub(pos))
                break
            else
                table.insert(res, line:sub(pos, comma_pos - 1))
                pos = comma_pos + 1
            end
        end
    end
    return res
end

-- Safely resolves file paths relative to document working directory
local function open_csv_file(src)
    local file = io.open(src, "r")
    if file then return file end

    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then
            return io.open(doc_dir .. src, "r")
        end
    end
    return nil
end

-- Reconstructs plain-text lines from Div AST while preserving soft/hard breaks
local function extract_lines_from_div(el)
    local lines = {}
    for _, block in ipairs(el.content) do
        if block.content then
            local current_line = {}
            for _, inline in ipairs(block.content) do
                if inline.t == "SoftBreak" or inline.t == "LineBreak" then
                    local line_str = trim(table.concat(current_line))
                    if line_str ~= "" then table.insert(lines, line_str) end
                    current_line = {}
                else
                    table.insert(current_line, pandoc.utils.stringify(inline))
                end
            end
            local final_line = trim(table.concat(current_line))
            if final_line ~= "" then table.insert(lines, final_line) end
        end
    end
    return lines
end

-- -----------------------------------------------------------------------------
-- 2. HTML TABLE GENERATOR ENGINE
-- -----------------------------------------------------------------------------

local function render_table(src, searchable, per_page, sortable, unsortable)
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
        table.insert(html, '        <th>' .. html_escape(trim(h)) .. '</th>')
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

-- -----------------------------------------------------------------------------
-- 3. PANDOC FILTER HOOKS
-- -----------------------------------------------------------------------------

-- Quick Syntax Handler (!dynamic-table: path/to/file.csv)
function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    if src then
        return render_table(trim(src), "true", "15", "true", "")
    end
    return nil
end

-- Customized Multiline Syntax Handler (::: {.dynamic-table})
function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end

    local src = el.attributes["src"]
    local searchable = "true"
    local per_page = "15"
    local sortable = "true"
    local unsortable_tbl = {}

    local lines = extract_lines_from_div(el)
    for _, line in ipairs(lines) do
        if not line:match("^#") then
            local key, val = line:match("^([%w_%-]+):%s*(.*)$")
            if key and val then
                key = key:lower()
                val = trim(val)
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

    return render_table(src, searchable, per_page, sortable, table.concat(unsortable_tbl, ","))
end

-- Document-Level Hook: Conditional Asset Injector
function Pandoc(doc)
    if has_dynamic_table then
        table.insert(doc.blocks, pandoc.RawBlock('html', CLIENT_ASSETS_HTML))
        has_dynamic_table = false
    end
    return doc
end