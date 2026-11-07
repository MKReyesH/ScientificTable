local function render_csv_table(filepath)
    local project_root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local clean_path = filepath:gsub("%s+", "")
    local full_path = project_root .. "/" .. clean_path
    
    local file = io.open(full_path, "r")
    if not file then
        return pandoc.Para({ pandoc.Str("[Error: Could not find CSV file at " .. clean_path .. "]") })
    end

    -- Parse CSV lines
    local rows = {}
    for line in file:lines() do
        if line:match("%S") then
            local row = {}
            local line_ext = line:gsub("[\r\n]", "") .. ","
            for val in line_ext:gmatch("([^,]*),") do
                local clean_val = val:gsub('^%s*(.-)%s*$', '%1'):gsub('^"(.*)"$', '%1')
                table.insert(row, clean_val)
            end
            table.insert(rows, row)
        end
    end
    file:close()

    if #rows == 0 then return nil end

    local table_id = "table_" .. tostring(math.random(100000, 999999))
    local html = {}

    -- Bootstrap 5 table structure matching Quarto themes
    table.insert(html, string.format('<div class="table-responsive my-3"><table id="%s" class="table table-striped table-hover table-bordered align-middle w-100">', table_id))
    
    -- Table Header
    table.insert(html, '<thead class="table-light"><tr>')
    for _, col in ipairs(rows[1]) do
        table.insert(html, string.format('<th>%s</th>', col))
    end
    table.insert(html, '</tr></thead><tbody>')
    
    -- Table Body
    for i = 2, #rows do
        table.insert(html, '<tr>')
        for _, val in ipairs(rows[i]) do
            table.insert(html, string.format('<td>%s</td>', val))
        end
        table.insert(html, '</tr>')
    end
    table.insert(html, '</tbody></table></div>')

    -- Standard DataTables initialization with native default sorting
    table.insert(html, string.format([[
    <link rel="stylesheet" href="https://cdn.datatables.net/2.0.8/css/dataTables.bootstrap5.min.css">
    <script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
    <script src="https://cdn.datatables.net/2.0.8/js/dataTables.min.js"></script>
    <script src="https://cdn.datatables.net/2.0.8/js/dataTables.bootstrap5.min.js"></script>
    <script>
      (function initTable() {
        if (typeof jQuery !== 'undefined' && $.fn.dataTable) {
          $('#%s').DataTable({
            responsive: true,
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
    ]], table_id))

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
