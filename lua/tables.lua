local function render_csv_table(filepath)
    local project_root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local clean_path = filepath:gsub("%s+", "")
    local full_path = project_root .. "/" .. clean_path
    
    local file = io.open(full_path, "r")
    if not file then
        return pandoc.Para({ pandoc.Str("[Error: Could not find CSV file at " .. clean_path .. "]") })
    end

    -- Read and parse CSV rows
    local rows = {}
    for line in file:lines() do
        if line:match("%S") then
            local row = {}
            for val in line:gmatch('([^,]+)') do
                -- Trim quotes and extra whitespace
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

    -- Build standard HTML table markup
    table.insert(html, string.format('<div class="table-responsive"><table id="%s" class="display" style="width:100%%">', table_id))
    
    -- Table Header (first line of CSV)
    table.insert(html, '<thead><tr>')
    for _, col in ipairs(rows[1]) do
        table.insert(html, string.format('<th>%s</th>', col))
    end
    table.insert(html, '</tr></thead><tbody>')
    
    -- Table Body (remaining lines)
    for i = 2, #rows do
        table.insert(html, '<tr>')
        for _, val in ipairs(rows[i]) do
            table.insert(html, string.format('<td>%s</td>', val))
        end
        table.insert(html, '</tr>')
    end
    table.insert(html, '</tbody></table></div>')

    -- Embed CDN links and DataTables initializer
    table.insert(html, string.format([[
    <link href="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css" rel="stylesheet" type="text/css">
    <script src="https://cdn.jsdelivr.net/npm/simple-datatables@latest" type="text/javascript"></script>
    <script>
      (function initTable() {
        if (typeof simpleDatatables !== 'undefined' && simpleDatatables.DataTable) {
          new simpleDatatables.DataTable("#%s", {
            searchable: true,
            fixedHeight: false,
            perPage: 10,
            perPageSelect: [5, 10, 25, 50]
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
    -- Intercept code blocks: ```csv-table ... ```
    CodeBlock = function(el)
        if el.classes:includes("csv-table") then
            return render_csv_table(el.text)
        end
    end,
    -- Intercept inline paragraphs: !csv-table: path/to/file.csv
    Para = function(el)
        local txt = pandoc.utils.stringify(el)
        local path = txt:match("^!csv%-table:%s*(.+)$")
        if path then
            return render_csv_table(path)
        end
    end
}