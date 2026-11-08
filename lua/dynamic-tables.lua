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
--    searchable: true            -- Optional (default: true)
--    per-page: 15                -- Optional (default: 15)
--    sortable: true              -- Optional (default: true)
--    column 0: unsortable        -- Disables header sorting
--    column 1: dropdown          -- Injects value filter dropdown
--    column 4: units(eV: 1, keV: 1e-3, MeV: 1e-6, GeV: 1e-9) -- Unit switcher
--    :::
-- =============================================================================

local has_dynamic_table = false

-- Client-side library & modular feature engine
local CLIENT_ASSETS_HTML = [[
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css">
<style>
  table.dynamic-table-target th {
    vertical-align: top !important;
  }
  .dynamic-table-control-container {
    display: block;
    margin-top: 4px;
  }
  .dynamic-table-dropdown-filter,
  .dynamic-table-unit-select {
    display: block;
    width: 100%;
    max-width: 120px;
    font-size: 0.8em;
    padding: 2px 4px;
    border-radius: 4px;
    border: 1px solid #ced4da;
    background-color: #fff;
    cursor: pointer;
  }
</style>
<script src="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js"></script>
<script>
  document.addEventListener("DOMContentLoaded", function () {
    const tables = document.querySelectorAll("table.dynamic-table-target");
    tables.forEach((table) => {
      const searchable = table.dataset.searchable !== "false";
      const sortable = table.dataset.sortable !== "false";
      const perPage = parseInt(table.dataset.perPage || "15", 10);
      
      let customColumns = [];
      if (table.dataset.columns) {
        try { customColumns = JSON.parse(table.dataset.columns); } 
        catch (e) { console.error("Error parsing columns metadata:", e); }
      }

      // 1. Build Simple-DataTables column rules
      const columnRules = [];
      customColumns.forEach(col => {
        if (col.type === "unsortable" || col.type === "dropdown" || col.type === "units") {
          // Keep custom controls from triggering accidental header sorts
        }
      });

      // 2. Instantiate Simple-DataTables
      const dt = new simpleDatatables.DataTable(table, {
        searchable: searchable,
        sortable: sortable,
        perPage: perPage,
        labels: {
          placeholder: "Search table...",
          perPage: "entries per page",
          noRows: "No entries found",
          info: "Showing {start} to {end} of {rows} entries",
        }
      });

      // 3. Attach custom column controls after table init
      dt.on("datatable.init", () => {
        setupCustomColumnFeatures(table, dt, customColumns);
      });
    });
  });

  function setupCustomColumnFeatures(table, dt, customColumns) {
    customColumns.forEach(col => {
      if (col.type === "dropdown") {
        setupDropdownFilter(table, dt, col.index);
      } else if (col.type === "units") {
        setupUnitConverter(table, dt, col);
      }
    });
  }

  // --- Feature 1: Header Dropdown Filter ---
  function setupDropdownFilter(table, dt, colIndex) {
    const ths = table.querySelectorAll("thead th");
    if (!ths || !ths[colIndex]) return;
    const th = ths[colIndex];

    // Read unique values from Simple-DataTables internal row storage
    const uniqueVals = new Set();
    dt.data.data.forEach(row => {
      const cellText = (row[colIndex] && row[colIndex].text) ? row[colIndex].text.trim() : "";
      if (cellText !== "") uniqueVals.add(cellText);
    });

    const container = document.createElement("div");
    container.className = "dynamic-table-control-container";

    const select = document.createElement("select");
    select.className = "dynamic-table-dropdown-filter";
    
    const defaultOpt = document.createElement("option");
    defaultOpt.value = "";
    defaultOpt.textContent = "All";
    select.appendChild(defaultOpt);

    Array.from(uniqueVals).sort().forEach(val => {
      const opt = document.createElement("option");
      opt.value = val;
      opt.textContent = val;
      select.appendChild(opt);
    });

    // Isolate dropdown interaction completely from sorting click events
    container.addEventListener("click", (e) => e.stopPropagation());
    select.addEventListener("click", (e) => e.stopPropagation());

    select.addEventListener("change", (e) => {
      const val = e.target.value.trim();
      // Search specifically within the target column index
      if (val === "") {
        dt.columns().search("", colIndex);
      } else {
        dt.columns().search(val, colIndex);
      }
    });

    container.appendChild(select);
    th.appendChild(container);
  }

  // --- Feature 2: Dynamic Unit Converter ---
  function setupUnitConverter(table, dt, col) {
    const ths = table.querySelectorAll("thead th");
    if (!ths || !ths[col.index] || !col.units || !col.map) return;
    const th = ths[col.index];

    const container = document.createElement("div");
    container.className = "dynamic-table-control-container";

    const select = document.createElement("select");
    select.className = "dynamic-table-unit-select";

    col.units.forEach(u => {
      const opt = document.createElement("option");
      opt.value = u;
      opt.textContent = u;
      select.appendChild(opt);
    });

    function formatNum(n) {
      if (isNaN(n)) return "";
      const abs = Math.abs(n);
      if (abs > 0 && (abs < 1e-3 || abs >= 1e4)) {
        return n.toExponential(2);
      }
      return Number(n.toFixed(4)).toString();
    }

    function applyConversion(unitName) {
      const factor = col.map[unitName];
      if (factor === undefined) return;

      // Safely update raw text inside table cells while retaining dataset attributes
      table.querySelectorAll("tbody tr").forEach(tr => {
        const cell = tr.children[col.index];
        if (cell && cell.dataset.order !== undefined) {
          const rawNum = parseFloat(cell.dataset.order);
          if (!isNaN(rawNum)) {
            cell.textContent = formatNum(rawNum * factor);
          }
        }
      });
    }

    container.addEventListener("click", (e) => e.stopPropagation());
    select.addEventListener("click", (e) => e.stopPropagation());
    select.addEventListener("change", (e) => applyConversion(e.target.value));

    container.appendChild(select);
    th.appendChild(container);
  }
</script>
]]

-- -----------------------------------------------------------------------------
-- 1. UTILITY HELPERS
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
-- 2. COLUMN RULE PARSER REGISTRY
-- -----------------------------------------------------------------------------

local function parse_units_args(args_str)
    local map = {}
    local units = {}
    for pair in args_str:gmatch("[^,]+") do
        local u, f = pair:match("^%s*([%w_%-%%]+)%s*:%s*([%d%.eE%-%+]+)%s*$")
        if u and f then
            map[u] = tonumber(f)
            table.insert(units, u)
        end
    end
    return map, units
end

local function parse_column_rule(line)
    local col_idx_str = line:match("^col%a*%s+(%d+)")
    if not col_idx_str then return nil end
    local col_idx = tonumber(col_idx_str)

    local body = line:match(":%s*(.*)$") or ""
    body = trim(body:lower())

    if body:match("^unsortable") then
        return { index = col_idx, type = "unsortable" }
    elseif body:match("^dropdown") then
        return { index = col_idx, type = "dropdown" }
    elseif body:match("^units%((.-)%)") then
        local args = line:match("units%((.-)%)")
        local map, units = parse_units_args(args)
        return { index = col_idx, type = "units", map = map, units = units }
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- 3. HTML TABLE RENDERER
-- -----------------------------------------------------------------------------

local function render_table(src, searchable, per_page, sortable, columns_meta)
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

    local columns_json = pandoc.json.encode(columns_meta or {})
    local headers = parse_csv_line(lines[1])
    local html = { '<div class="dynamic-table-wrapper">' }

    local table_tag = string.format(
        '  <table class="dynamic-table-target table table-striped table-hover" data-searchable="%s" data-per-page="%s" data-sortable="%s" data-columns="%s">',
        html_escape(searchable or "true"),
        html_escape(per_page or "15"),
        html_escape(sortable or "true"),
        html_escape(columns_json)
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
-- 4. PANDOC FILTER HOOKS
-- -----------------------------------------------------------------------------

-- Quick Syntax Handler (!dynamic-table: path/to/file.csv)
function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    if src then
        return render_table(trim(src), "true", "15", "true", {})
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
    local columns_meta = {}

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
            elseif line:lower():match("^col") then
                local col_rule = parse_column_rule(line)
                if col_rule then
                    table.insert(columns_meta, col_rule)
                end
            end
        end
    end

    if not src or src == "" then return nil end

    return render_table(src, searchable, per_page, sortable, columns_meta)
end

-- Document-Level Hook: Asset Injector
function Pandoc(doc)
    if has_dynamic_table then
        table.insert(doc.blocks, pandoc.RawBlock('html', CLIENT_ASSETS_HTML))
        has_dynamic_table = false
    end
    return doc
end
