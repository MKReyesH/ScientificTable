local table_counter = 0
local assets_injected = false

local function escape_html(str)
    return (str:gsub("&", "&amp;")
               :gsub("<", "&lt;")
               :gsub(">", "&gt;")
               :gsub('"', "&quot;"))
end

-- Parses standard CSV lines handling quoted fields and escaped quotes
local function parse_csv_line(line)
    local res = {}
    local pos = 1
    local line_len = #line
    while pos <= line_len do
        local c = line:sub(pos, pos)
        if c == '"' then
            local txt = ""
            pos = pos + 1
            while pos <= line_len do
                local d = line:sub(pos, pos)
                if d == '"' then
                    if line:sub(pos + 1, pos + 1) == '"' then
                        txt = txt .. '"'
                        pos = pos + 2
                    else
                        pos = pos + 1
                        break
                    end
                else
                    txt = txt .. d
                    pos = pos + 1
                end
            end
            table.insert(res, txt)
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local start_p, end_p = line:find(',', pos, true)
            if start_p then
                table.insert(res, line:sub(pos, start_p - 1))
                pos = end_p + 1
            else
                table.insert(res, line:sub(pos))
                break
            end
        end
    end
    return res
end

local function render_csv_table(filepath)
    local project_root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local clean_path = filepath:match("^%s*(.-)%s*$")
    local full_path = project_root .. "/" .. clean_path

    local file = io.open(full_path, "r")
    if not file then
        return pandoc.Para({ pandoc.Str("[Error: Could not find CSV file at " .. clean_path .. "]") })
    end

    local rows = {}
    for line in file:lines() do
        line = line:gsub("[\r\n]", "")
        if line:match("%S") then
            table.insert(rows, parse_csv_line(line))
        end
    end
    file:close()

    if #rows == 0 then return nil end

    -- Fallback to native Pandoc Table for PDF/DOCX rendering
    if not FORMAT:match("html") then
        local headers = {}
        for _, col in ipairs(rows[1]) do
            table.insert(headers, pandoc.Plain({ pandoc.Str(col) }))
        end
        local body_rows = {}
        for i = 2, #rows do
            local row_cells = {}
            for _, val in ipairs(rows[i]) do
                table.insert(row_cells, pandoc.Plain({ pandoc.Str(val) }))
            end
            table.insert(body_rows, row_cells)
        end
        return pandoc.utils.from_simple_table(pandoc.SimpleTable({}, {}, headers, body_rows))
    end

    table_counter = table_counter + 1
    local table_id = "csv_table_" .. tostring(table_counter)
    local html = {}

    -- Inject assets once per HTML render
    if not assets_injected then
        table.insert(html, [[
<link rel="stylesheet" href="https://cdn.datatables.net/2.0.8/css/dataTables.bootstrap5.min.css">
<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
<script src="https://cdn.datatables.net/2.0.8/js/dataTables.min.js"></script>
<script src="https://cdn.datatables.net/2.0.8/js/dataTables.bootstrap5.min.js"></script>
]])
        assets_injected = true
    end

    table.insert(html, string.format('<div class="table-responsive my-3"><table id="%s" class="table table-striped table-hover table-bordered align-middle w-100">', table_id))
    table.insert(html, '<thead class="table-light"><tr>')
    for _, col in ipairs(rows[1]) do
        table.insert(html, string.format('<th>%s</th>', escape_html(col)))
    end
    table.insert(html, '</tr></thead><tbody>')

    for i = 2, #rows do
        table.insert(html, '<tr>')
        for _, val in ipairs(rows[i]) do
            table.insert(html, string.format('<td>%s</td>', escape_html(val)))
        end
        table.insert(html, '</tr>')
    end
    table.insert(html, '</tbody></table></div>')

    table.insert(html, string.format([=[
<script>
  (function initTable() {
    if (typeof jQuery !== 'undefined' && $.fn.dataTable) {
      $('#%s').DataTable({
        responsive: true,
        order: [[0, 'asc']],
        orderMulti: false,
        pageLength: 10,
        lengthMenu: [5, 10, 25, 50, 100],
        language: {
          search: "_INPUT_",
          searchPlaceholder: "Search table..."
        }
      });
    } else {
      setTimeout(initTable, 50);
    }
  })();
</script>
]=], table_id))

    return pandoc.RawBlock("html", table.concat(html, "\n"))
end

return {
    CodeBlock = function(el)
        if el.classes:includes("csv-table") then
            return render_csv_table(el.text)
        end
    end,
    Para = function(el)
        local txt = pandoc.utils.stringify(el)
        local path = txt:match("^!csv%-table:%s*(.+)$")
        if path then
            return render_csv_table(path)
        end
    end
}
