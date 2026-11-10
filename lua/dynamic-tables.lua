-- =============================================================================
-- DYNAMIC CSV TABLE RENDERER & HYDRATOR (Pandoc Lua Filter)
-- Strategy A: Tabulator.js + Native Bootstrap 5 Integration
-- =============================================================================

local has_dynamic_table = false

-- Use [=[ ... ]=] long bracket syntax to prevent JS array indexing brackets from ending Lua string
local CLIENT_ASSETS_HTML = [=[
<link rel="stylesheet" href="https://unpkg.com/tabulator-tables@5.5.2/dist/css/tabulator_bootstrap5.min.css">
<style>
  .tabulator-container-wrap { margin: 1.5rem 0; font-size: 0.9em; }
  .tabulator-top-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; flex-wrap: wrap; gap: 8px; }
  .tabulator-search-input { width: 220px; }
  .tabulator-title-wrap { display: flex; flex-direction: column; gap: 4px; width: 100%; }
  .tabulator-unit-select { font-size: 0.75rem !important; padding-top: 1px !important; padding-bottom: 1px !important; }
</style>
<script src="https://unpkg.com/tabulator-tables@5.5.2/dist/js/tabulator.min.js"></script>
<script>
class TabulatorTableController {
  constructor(container) {
    this.container = container;
    this.headers = JSON.parse(container.dataset.headers || "[]");
    this.rows = JSON.parse(container.dataset.rows || "[]");
    this.config = JSON.parse(container.dataset.columns || "[]");
    this.perPage = parseInt(container.dataset.perpage || "15", 10);
    this.searchable = container.dataset.searchable !== "false";
    this.sortable = container.dataset.sortable !== "false";
    
    this.unitFactors = {}; // colIdx -> multiplier
    this.table = null;
    this.init();
  }

  init() {
    // 1. Register unit factor defaults
    this.config.forEach(col => {
      if (col.units && col.map) {
        const defaultUnit = col.units[0];
        this.unitFactors[col.index] = col.map[defaultUnit] !== undefined ? col.map[defaultUnit] : 1;
      }
    });

    // 2. Build HTML layout container using Bootstrap classes
    const tableElId = "tabulator-table-" + Math.random().toString(36).substring(2, 9);
    this.container.innerHTML = `
      <div class="tabulator-top-bar">
        ${this.searchable ? '<input type="text" class="form-control form-control-sm tabulator-search-input" placeholder="Search table...">' : '<div></div>'}
      </div>
      <div id="${tableElId}"></div>
    `;

    // 3. Build Column Definitions
    const columns = this.headers.map((h, idx) => {
      const colCfg = this.config.find(c => c.index === idx) || {};
      const isNum = colCfg.type === "number" || colCfg.units !== undefined;

      const colDef = {
        titleFormatter: () => {
          const titleWrap = document.createElement("div");
          titleWrap.className = "tabulator-title-wrap";
          
          const label = document.createElement("span");
          label.className = "fw-bold";
          label.textContent = h;
          titleWrap.appendChild(label);

          if (colCfg.units && colCfg.map) {
            const select = document.createElement("select");
            select.className = "form-select form-select-sm tabulator-unit-select mt-1";
            select.innerHTML = colCfg.units.map(u => `<option value="${u}">${u}</option>`).join("");
            select.addEventListener("click", e => e.stopPropagation());
            select.addEventListener("change", e => {
              const factor = colCfg.map[e.target.value];
              if (factor !== undefined) {
                this.unitFactors[idx] = factor;
                this.table.redraw(true); // Re-evaluate formatters without disturbing sort
              }
            });
            titleWrap.appendChild(select);
          }
          return titleWrap;
        },
        field: "col_" + idx,
        headerSort: colCfg.sortable !== undefined ? colCfg.sortable : this.sortable,
        // SYMMETRY FIX: Apply alignEmptyValues: "bottom" to ALL columns (numeric & string)
        sorter: isNum ? "number" : "string",
        sorterParams: { alignEmptyValues: "bottom" },
        headerHozAlign: "left"
      };

      // Scientific Formatting for numeric/unit columns
      if (isNum) {
        colDef.formatter = (cell) => {
          const val = cell.getValue();
          if (val === null || val === undefined || val === "") return "";
          const num = Number(val);
          if (isNaN(num)) return String(val);
          
          const factor = this.unitFactors[idx] || 1;
          const converted = num * factor;
          const abs = Math.abs(converted);
          
          return (abs > 0 && (abs < 1e-3 || abs >= 1e4))
            ? converted.toExponential(2)
            : Number(converted.toFixed(4)).toString();
        };
      }

      // Native Multi-Column Dropdown Filter with Bootstrap styling
      if (colCfg.dropdown) {
        colDef.headerFilter = "list";
        colDef.headerFilterParams = {
          valuesLookup: "all",
          clearable: true,
          elementAttributes: {
            class: "form-select form-select-sm mt-1 py-0 px-2",
            style: "font-size: 0.75rem;"
          }
        };
      }

      return colDef;
    });

    // 4. Initialize Tabulator Instance
    this.table = new Tabulator("#" + tableElId, {
      data: this.rows,
      columns: columns,
      layout: "fitColumns",
      responsiveLayout: "collapse",
      pagination: "local",
      paginationSize: this.perPage,
      paginationSizeSelector: [10, 15, 25, 50],
      movableColumns: false
    });

    // 5. Global Search Binding
    if (this.searchable) {
      const searchInput = this.container.querySelector(".tabulator-search-input");
      searchInput.addEventListener("keyup", (e) => {
        const query = e.target.value.toLowerCase().trim();
        if (query === "") {
          this.table.clearFilter();
        } else {
          this.table.setFilter((data) => {
            return Object.values(data).some(val => String(val || "").toLowerCase().includes(query));
          });
        }
      });
    }
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".tabulator-container-wrap").forEach(el => new TabulatorTableController(el));
});
</script>
]=]

-- -----------------------------------------------------------------------------
-- LUA HELPERS & PARSERS
-- -----------------------------------------------------------------------------

local function trim(s) 
    return s and s:match("^%s*(.-)%s*$") or "" 
end

local function html_escape(s)
    return s and (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) or ""
end

local function parse_csv_line(line)
    local res, pos, len = {}, 1, #line
    while pos <= len do
        if line:sub(pos, pos) == '"' then
            local val = ""
            pos = pos + 1
            while pos <= len do
                local c = line:sub(pos, pos)
                if c == '"' then
                    if line:sub(pos + 1, pos + 1) == '"' then val = val .. '"'; pos = pos + 2
                    else pos = pos + 1; break end
                else val = val .. c; pos = pos + 1 end
            end
            table.insert(res, trim(val))
            if line:sub(pos, pos) == ',' then pos = pos + 1 end
        else
            local comma_pos = line:find(",", pos)
            if not comma_pos then 
                table.insert(res, trim(line:sub(pos)))
                break
            else 
                table.insert(res, trim(line:sub(pos, comma_pos - 1)))
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
        if doc_dir then return io.open(doc_dir .. src, "r") end
    end
    return nil
end

local function extract_lines_from_div(el)
    local lines = {}
    for _, block in ipairs(el.content) do
        if block.content then
            local current = {}
            for _, inline in ipairs(block.content) do
                if inline.t == "SoftBreak" or inline.t == "LineBreak" then
                    local l = trim(table.concat(current))
                    if l ~= "" then table.insert(lines, l) end
                    current = {}
                else table.insert(current, pandoc.utils.stringify(inline)) end
            end
            local final = trim(table.concat(current))
            if final ~= "" then table.insert(lines, final) end
        end
    end
    return lines
end

local function parse_column_rule(line)
    local col_idx = tonumber(line:match("^col%a*%s+(%d+)"))
    if not col_idx then return nil end
    local body = trim(line:match(":%s*(.*)$") or "")
    local rule = { index = col_idx }

    local units_str = body:match("units%((.-)%)")
    if units_str then
        local map, units = {}, {}
        for pair in units_str:gmatch("[^,]+") do
            local u, f = pair:match("^%s*(.-)%s*:%s*([%d%.eE%-%+]+)%s*$")
            if u and f then map[u] = tonumber(f); table.insert(units, u) end
        end
        rule.units = units
        rule.map = map
        body = body:gsub("units%((.-)%)", "")
    end

    for tag in body:gmatch("[^,]+") do
        tag = trim(tag:lower())
        if tag == "unsortable" then rule.sortable = false
        elseif tag == "sortable" then rule.sortable = true
        elseif tag == "dropdown" then rule.dropdown = true
        elseif tag == "string" or tag == "text" then rule.type = "string"
        elseif tag == "number" or tag == "numeric" then rule.type = "number" end
    end

    return rule
end

-- -----------------------------------------------------------------------------
-- CORE TABLE BUILDER & PANDOC HOOKS
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

    local raw_headers = parse_csv_line(lines[1])
    local headers = {}
    for _, h in ipairs(raw_headers) do
        table.insert(headers, trim(h))
    end

    local rows = {}
    for i = 2, #lines do
        local raw_row = parse_csv_line(lines[i])
        local row_obj = {}
        for j = 1, #headers do
            local cell_val = trim(raw_row[j] or "")
            row_obj["col_" .. tostring(j - 1)] = cell_val
        end
        table.insert(rows, row_obj)
    end

    local html = string.format(
        '<div class="tabulator-container-wrap" data-headers="%s" data-rows="%s" data-columns="%s" data-searchable="%s" data-perpage="%s" data-sortable="%s"></div>',
        html_escape(pandoc.json.encode(headers)),
        html_escape(pandoc.json.encode(rows)),
        html_escape(pandoc.json.encode(columns_meta or {})),
        html_escape(searchable or "true"),
        html_escape(per_page or "15"),
        html_escape(sortable or "true")
    )

    return pandoc.RawBlock('html', html)
end

function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    local src = txt:match("^%!dynamic%-table:%s*(.+)$")
    return src and render_table(trim(src), "true", "15", "true", {}) or nil
end

function Div(el)
    if not el.classes:includes("dynamic-table") then return nil end
    local src = el.attributes["src"]
    local searchable, per_page, sortable = "true", "15", "true"
    local columns_meta = {}

    for _, line in ipairs(extract_lines_from_div(el)) do
        if not line:match("^#") then
            local key, val = line:match("^([%w_%-]+):%s*(.*)$")
            if key and val then
                key = key:lower(); val = trim(val)
                if key == "src" then src = val
                elseif key == "searchable" then searchable = val
                elseif key == "per-page" then per_page = val
                elseif key == "sortable" then sortable = val end
            elseif line:lower():match("^col") then
                local col_rule = parse_column_rule(line)
                if col_rule then table.insert(columns_meta, col_rule) end
            end
        end
    end

    return (src and src ~= "") and render_table(src, searchable, per_page, sortable, columns_meta) or nil
end

function Pandoc(doc)
    if has_dynamic_table then
        table.insert(doc.blocks, pandoc.RawBlock('html', CLIENT_ASSETS_HTML))
        has_dynamic_table = false
    end
    return doc
end