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
            for val in line:gmatch('([^,]+)') do
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
    
    -- Header
    table.insert(html, '<thead class="table-light"><tr>')
    for _, col in ipairs(rows[1]) do
        table.insert(html, string.format('<th>%s</th>', col))
    end
    table.insert(html, '</tr></thead><tbody>')
    
    -- Body
    for i = 2, #rows do
        table.insert(html, '<tr>')
        for _, val in ipairs(rows[i]) do
            local num = tonumber(val)
            if num then
                table.insert(html, string.format('<td data-order="%s">%s</td>', tostring(num), val))
            else
                table.insert(html, string.format('<td>%s</td>', val))
            end
        end
        table.insert(html, '</tr>')
    end
    table.insert(html, '</tbody></table></div>')

    -- Bootstrap 5 DataTables dependencies + Scientific Notation & Empty Cell Sorter
    table.insert(html, string.format([[
    <link rel="stylesheet" href="https://cdn.datatables.net/2.0.8/css/dataTables.bootstrap5.min.css">
    <script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
    <script src="https://cdn.datatables.net/2.0.8/js/dataTables.min.js"></script>
    <script src="https://cdn.datatables.net/2.0.8/js/dataTables.bootstrap5.min.js"></script>
    <script>
      (function initTable() {
        if (typeof jQuery !== 'undefined' && $.fn.dataTable) {
          
          // Number parser with scientific notation support
          function parseNumSci(d) {
            if (d === null || d === undefined) return null;
            var str = String(d).replace(/<[^>]*>/g, '').trim();
            if (str === '' || str === '-' || str === 'N/A') return null;
            var n = Number(str);
            return isNaN(n) ? null : n;
          }

          if (!$.fn.dataTable.ext.type.detect.includes(sciDetect)) {
            function sciDetect(d) {
              return (parseNumSci(d) !== null) ? 'num-sci' : null;
            }
            $.fn.dataTable.ext.type.detect.unshift(sciDetect);

            // Scientific Notation Ascending: Empty cells ALWAYS last
            $.fn.dataTable.ext.type.order['num-sci-asc'] = function (a, b) {
              var x = parseNumSci(a), y = parseNumSci(b);
              if (x === null && y === null) return 0;
              if (x === null) return 1;
              if (y === null) return -1;
              return (x < y) ? -1 : ((x > y) ? 1 : 0);
            };

            // Scientific Notation Descending: Empty cells ALWAYS last
            $.fn.dataTable.ext.type.order['num-sci-desc'] = function (a, b) {
              var x = parseNumSci(a), y = parseNumSci(b);
              if (x === null && y === null) return 0;
              if (x === null) return 1;
              if (y === null) return -1;
              return (x < y) ? 1 : ((x > y) ? -1 : 0);
            };

            // String/Text Columns: Empty cells ALWAYS last
            function parseStr(d) {
              if (d === null || d === undefined) return null;
              var str = String(d).replace(/<[^>]*>/g, '').trim();
              return str === '' ? null : str;
            }
            $.fn.dataTable.ext.type.order['string-asc'] = function (a, b) {
              var x = parseStr(a), y = parseStr(b);
              if (x === null && y === null) return 0;
              if (x === null) return 1;
              if (y === null) return -1;
              return x.localeCompare(y, undefined, { numeric: true, sensitivity: 'base' });
            };
            $.fn.dataTable.ext.type.order['string-desc'] = function (a, b) {
              var x = parseStr(a), y = parseStr(b);
              if (x === null && y === null) return 0;
              if (x === null) return 1;
              if (y === null) return -1;
              return y.localeCompare(x, undefined, { numeric: true, sensitivity: 'base' });
            };
            $.fn.dataTable.ext.type.order['html-asc'] = $.fn.dataTable.ext.type.order['string-asc'];
            $.fn.dataTable.ext.type.order['html-desc'] = $.fn.dataTable.ext.type.order['string-desc'];
          }

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
