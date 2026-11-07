
-- ============================================================
-- CSV TABLE FILTER FOR QUARTO
-- ============================================================

local project_root = os.getenv("QUARTO_PROJECT_DIR") or "."

local table_counter = 0
local datatables_loaded = false


-- ------------------------------------------------------------
-- HTML escaping
-- ------------------------------------------------------------

local function escape_html(value)

    value = tostring(value or "")

    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    value = value:gsub("'", "&#39;")

    return value

end


-- ------------------------------------------------------------
-- CSV parser
-- ------------------------------------------------------------

local function parse_csv(content)

    local rows = {}
    local row = {}
    local field = {}

    local in_quotes = false
    local i = 1

    content = content:gsub("^\239\187\191", "")

    local function finish_field()
        table.insert(row, table.concat(field))
        field = {}
    end

    local function finish_row()

        finish_field()

        if #row > 1 or row[1] ~= "" then
            table.insert(rows, row)
        end

        row = {}

    end

    while i <= #content do

        local char = content:sub(i, i)

        if in_quotes then

            if char == '"' then

                if content:sub(i + 1, i + 1) == '"' then
                    table.insert(field, '"')
                    i = i + 1
                else
                    in_quotes = false
                end

            else

                table.insert(field, char)

            end

        else

            if char == '"' and #field == 0 then

                in_quotes = true

            elseif char == ',' then

                finish_field()

            elseif char == '\n' then

                finish_row()

            elseif char ~= '\r' then

                table.insert(field, char)

            end

        end

        i = i + 1

    end

    if in_quotes then
        return nil, "Unclosed quoted field in CSV file."
    end

    if #field > 0 or #row > 0 then
        finish_row()
    end

    return rows

end


-- ------------------------------------------------------------
-- Error message
-- ------------------------------------------------------------

local function render_error(message)

    return pandoc.RawBlock(
        "html",
        '<div class="alert alert-danger">' ..
        escape_html(message) ..
        '</div>'
    )

end


-- ------------------------------------------------------------
-- Render CSV table
-- ------------------------------------------------------------

local function render_csv_table(filepath)

    filepath = filepath:gsub("^%s*(.-)%s*$", "%1")
    filepath = filepath:gsub("\\", "/")

    if filepath == "" then
        return render_error("CSV filename is empty.")
    end

    local full_path

    if filepath:match("^/") or filepath:match("^%a:/") then
        full_path = filepath
    else
        full_path = project_root .. "/" .. filepath
    end

    local file = io.open(full_path, "rb")

    if not file then
        return render_error("Could not find CSV file: " .. filepath)
    end

    local content = file:read("*a")
    file:close()

    local rows, err = parse_csv(content)

    if not rows then
        return render_error(err)
    end

    if #rows == 0 then
        return render_error("CSV file is empty.")
    end

    local ncols = #rows[1]

    for i, row in ipairs(rows) do

        if #row ~= ncols then
            return render_error(
                "Inconsistent number of columns in row " .. i
            )
        end

    end

    -- Unique table ID
    table_counter = table_counter + 1

    local table_id = "csv_table_" .. table_counter

    local html = {}

    -- --------------------------------------------------------
    -- HTML table
    -- --------------------------------------------------------

    table.insert(html, [[
<div class="table-responsive my-3">
]])

    table.insert(html, string.format(
        '<table id="%s" class="table table-striped table-hover table-bordered align-middle w-100">',
        table_id
    ))

    -- Header
    table.insert(html, '<thead class="table-light"><tr>')

    for _, col in ipairs(rows[1]) do

        table.insert(
            html,
            '<th>' .. escape_html(col) .. '</th>'
        )

    end

    table.insert(html, '</tr></thead><tbody>')

    -- Body
    for i = 2, #rows do

        table.insert(html, '<tr>')

        for j = 1, ncols do

            table.insert(
                html,
                '<td>' .. escape_html(rows[i][j]) .. '</td>'
            )

        end

        table.insert(html, '</tr>')

    end

    table.insert(html, '</tbody></table></div>')


    -- --------------------------------------------------------
    -- DataTables dependencies
    -- --------------------------------------------------------

    if not datatables_loaded then

        datatables_loaded = true

        table.insert(html, [[

<link rel="stylesheet"
 href="https://cdn.datatables.net/2.0.8/css/dataTables.bootstrap5.min.css">

<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>

<script src="https://cdn.datatables.net/2.0.8/js/dataTables.min.js"></script>

<script src="https://cdn.datatables.net/2.0.8/js/dataTables.bootstrap5.min.js"></script>

]])

    end


    -- --------------------------------------------------------
    -- DataTables initialization
    -- --------------------------------------------------------

    table.insert(html, string.format([=[
<script>

(function initTable() {

    if (typeof jQuery !== 'undefined' && $.fn.dataTable) {

        const table = $('#%s');

        if (!$.fn.DataTable.isDataTable(table)) {

            table.DataTable({

                ordering: true,

                order: [],

                orderMulti: false,

                searching: true,

                paging: true,

                pageLength: 10,

                lengthMenu: [5, 10, 25, 50, 100],

                language: {

                    search: "_INPUT_",

                    searchPlaceholder: "Search table...",

                    lengthMenu: "Show _MENU_ entries",

                    info: "Showing _START_ to _END_ of _TOTAL_ entries",

                    infoEmpty: "No entries available",

                    zeroRecords: "No matching records found",

                    emptyTable: "No data available"

                }

            });

        }

    } else {

        setTimeout(initTable, 50);

    }

})();

</script>
]=], table_id))


    return pandoc.RawBlock("html", table.concat(html, "\n"))

end


-- ------------------------------------------------------------
-- Quarto filter interface
-- ------------------------------------------------------------

return {

    CodeBlock = function(el)

        if el.classes:includes("csv-table") then
            return render_csv_table(el.text)
        end

    end,

    Para = function(el)

        local txt = pandoc.utils.stringify(el)

        local filepath = txt:match("^!csv%-table:%s*(.+)$")

        if filepath then
            return render_csv_table(filepath)
        end

    end

}
