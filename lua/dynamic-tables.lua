local assets_injected = false

local function escape_html(str)
    return str and str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;") or ""
end

-- CSV parser supporting quoted fields, embedded commas, escaped quotes (""), and newlines
local function parse_csv(text)
    local rows, row, field, in_quotes = {}, {}, "", false
    local i, len = 1, #text

    while i <= len do
        local c = text:sub(i, i)
        if in_quotes then
            if c == '"' then
                if i < len and text:sub(i + 1, i + 1) == '"' then
                    field = field .. '"'
                    i = i + 1
                else
                    in_quotes = false
                end
            else
                field = field .. c
            end
        else
            if c == '"' then
                in_quotes = true
            elseif c == ',' then
                table.insert(row, field)
                field = ""
            elseif c == '\n' then
                table.insert(row, field)
                table.insert(rows, row)
                row, field = {}, ""
            elseif c ~= '\r' then
                field = field .. c
            end
        end
        i = i + 1
    end

    if #field > 0 or #row > 0 then
        table.insert(row, field)
        table.insert(rows, row)
    end
    return rows
end

-- Path resolution helper (checks project root, then document directory)
local function read_csv(filepath, doc_path)
    local clean_path = filepath:match("^%s*(.-)%s*$")
    local root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local doc_dir = doc_path and doc_path:match("(.*[/\\])") or ""
    
    local file = io.open(root .. "/" .. clean_path, "r") or 
                 (doc_dir ~= "" and io.open(doc_dir .. clean_path, "r"))
    if not file then return nil, clean_path end

    local content = file:read("*a")
    file:close()
    return content, clean_path
end

-- Helper to construct native Pandoc AST cell elements
local function to_cells(row, num_cols)
    local cells = {}
    for c = 1, num_cols do
        table.insert(cells, pandoc.Plain({ pandoc.Str(row[c] or "") }))
    end
    return cells
end

local function render_csv_table(filepath, doc_path)
    local content, clean_path = read_csv(filepath, doc_path)
    if not content then
        return pandoc.Para({ pandoc.Str("[Error: Could not find CSV file at " .. (clean_path or filepath) .. "]") })
    end

    local rows = parse_csv(content)
    if #rows == 0 then return nil end
    local num_cols = #rows[1]

    -- Non-HTML output fallback (PDF / DOCX / LaTeX)
    if not (FORMAT:match("html") or FORMAT:match("revealjs")) then
        local headers = to_cells(rows[1], num_cols)
        local body = {}
        for i = 2, #rows do
            table.insert(body, to_cells(rows[i], num_cols))
        end
        return pandoc.utils.from_simple_table(pandoc.SimpleTable({}, {}, headers, body))
    end

    -- HTML output construction
    local html = {}

    -- Inject assets & single global initializer once per render using [=[ ... ]=]
    if not assets_injected then
        table.insert(html, [=[
<link rel="stylesheet" href="https://cdn.datatables.net/2.0.8/css/dataTables.bootstrap5.min.css">
<script src="https://cdn.datatables.net/2.0.8/js/dataTables.min.js"></script>
<script src="https://cdn.datatables.net/2.0.8/js/dataTables.bootstrap5.min.js"></script>
<script>
  (function initTables(retries) {
    if (window.jQuery && $.fn.dataTable) {
      $('.csv-datatable:not(.dataTable)').DataTable({
        responsive: true,
        order: [[0, 'asc']],
        orderMulti: false,
        pageLength: 10,
        lengthMenu: [5, 10, 25, 50, 100],
        language: { search: "_INPUT_", searchPlaceholder: "Search table..." }
      });
    } else if ((retries || 0) < 50) {
      setTimeout(function() { initTables((retries || 0) + 1); }, 100);
    }
  })();
</script>
]=])
        assets_injected = true
    end

    table.insert(html, '<div class="table-responsive my-3"><table class="table table-striped table-hover table-bordered align-middle w-100 csv-datatable"><thead><tr>')
    for c = 1, num_cols do
        table.insert(html, string.format('<th>%s</th>', escape_html(rows[1][c])))
    end
    table.insert(html, '</tr></thead><tbody>')

    for i = 2, #rows do
        table.insert(html, '<tr>')
        for c = 1, num_cols do
            table.insert(html, string.format('<td>%s</td>', escape_html(rows[i][c])))
        end
        table.insert(html, '</tr>')
    end
    table.insert(html, '</tbody></table></div>')

    return pandoc.RawBlock("html", table.concat(html))
end

return {
    CodeBlock = function(el)
        if el.classes:includes("csv-table") then
            return render_csv_table(el.text, PANDOC_STATE.input_files[1])
        end
    end,
    Para = function(el)
        local path = pandoc.utils.stringify(el):match("^!csv%-table:%s*(.+)$")
        if path then
            return render_csv_table(path, PANDOC_STATE.input_files[1])
        end
    end
}
