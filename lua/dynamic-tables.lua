-- =============================================================================
-- DYNAMIC CSV TABLE RENDERER & HYDRATOR (Pandoc Lua Filter)
-- Option A Architecture: Native HTML5 data-order + Client-side UI Controller
-- =============================================================================

local has_dynamic_table = false

-- Use [=[ ... ]=] long brackets to safely wrap JavaScript code without ]] conflicts
local CLIENT_ASSETS_HTML = [=[
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css">
<style>
  table.dynamic-table-target th { vertical-align: top !important; }
  .dynamic-table-ctrl-wrap { display: block; margin-top: 4px; font-weight: normal; }
  .dynamic-table-ctrl-select {
    display: block; width: 100%; max-width: 120px; font-size: 0.8em;
    padding: 2px 4px; border-radius: 4px; border: 1px solid #ced4da; background: #fff; cursor: pointer;
  }
</style>
<script src="https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js"></script>
<script>
  class DynamicTableController {
    constructor(tableEl) {
      this.table = tableEl;
      this.config = JSON.parse(tableEl.dataset.columns || "[]");
      this.globalSortable = tableEl.dataset.sortable !== "false";
      this.unitFactors = {};   // colIndex -> activeMultiplier
      this.activeFilters = {}; // colIndex -> selectedFilterValue
      this.init();
    }

    init() {
      // Build simple-datatables column configuration (Native data-order sorting)
      const columnRules = this.config.map(col => {
        const rule = { select: col.index };
        if (col.sortable !== undefined) rule.sortable = col.sortable;
        else if (!this.globalSortable) rule.sortable = false;
        if (col.type) rule.type = col.type;
        return rule;
      });

      this.dt = new simpleDatatables.DataTable(this.table, {
        searchable: this.table.dataset.searchable !== "false",
        sortable: true,
        perPage: parseInt(this.table.dataset.perPage || "15", 10),
        columns: columnRules.length > 0 ? columnRules : undefined,
        labels: { 
          placeholder: "Search table...", 
          perPage: "entries per page", 
          noRows: "No entries found", 
          info: "Showing {start} to {end} of {rows} entries" 
        }
      });

      this.dt.on("datatable.init", () => {
        this.buildHeaderControls();
      });

      // Synchronize DOM state across pagination, sorting, and per-page redraws
      const syncUI = () => {
        this.applyUnitConversions();
        this.applyCombinedFilters();
      };

      this.dt.on("datatable.page", syncUI);
      this.dt.on("datatable.sort", syncUI);
      this.dt.on("datatable.perpage", syncUI);
    }

    buildHeaderControls() {
      this.config.forEach(col => {
        const th = this.table.querySelectorAll("thead th")[col.index];
        if (!th) return;

        const wrap = document.createElement("div");
        wrap.className = "dynamic-table-ctrl-wrap";

        // Multi-column dropdown filter construction
        if (col.dropdown) {
          const uniqueVals = this.getUniqueColumnValues(col.index);
          const select = this.createSelectElement(uniqueVals, "All");
          select.addEventListener("change", (e) => {
            this.activeFilters[col.index] = e.target.value.trim();
            this.applyCombinedFilters();
          });
          wrap.appendChild(select);
        }

        // Unit conversion dropdown construction
        if (col.units && col.map) {
          const defaultUnit = col.units[0];
          this.unitFactors[col.index] = col.map[defaultUnit] !== undefined ? col.map[defaultUnit] : 1;
          const select = this.createSelectElement(col.units);
          select.addEventListener("change", (e) => {
            const factor = col.map[e.target.value];
            if (factor !== undefined) {
              this.unitFactors[col.index] = factor;
              this.applyUnitConversions();
              if (this.dt && typeof this.dt.update === "function") {
                this.dt.update();
              }
            }
          });
          wrap.appendChild(select);
        }

        if (wrap.children.length > 0) {
          wrap.addEventListener("click", (e) => e.stopPropagation());
          th.appendChild(wrap);
        }
      });
    }

    createSelectElement(options, defaultLabel) {
      const select = document.createElement("select");
      select.className = "dynamic-table-ctrl-select";
      let html = defaultLabel ? `<option value="">${defaultLabel}</option>` : "";
      options.forEach(opt => { html += `<option value="${opt}">${opt}</option>`; });
      select.innerHTML = html;
      return select;
    }

    getUniqueColumnValues(colIndex) {
      const uniqueSet = new Set();
      this.table.querySelectorAll("tbody tr").forEach(tr => {
        const cell = tr.children[colIndex];
        if (cell) {
          const txt = cell.textContent.trim();
          if (txt !== "") uniqueSet.add(txt);
        }
      });
      return Array.from(uniqueSet).sort();
    }

    applyUnitConversions() {
      const colsToConvert = Object.keys(this.unitFactors);
      if (colsToConvert.length === 0) return;

      this.table.querySelectorAll("tbody tr").forEach(tr => {
        colsToConvert.forEach(colIdx => {
          const cell = tr.children[colIdx];
          if (cell && cell.dataset.baseOrder !== undefined) {
            const baseNum = parseFloat(cell.dataset.baseOrder);
            if (!isNaN(baseNum)) {
              const factor = this.unitFactors[colIdx];
              const converted = baseNum * factor;
              cell.dataset.order = converted.toString();

              const abs = Math.abs(converted);
              cell.textContent = (abs > 0 && (abs < 1e-3 || abs >= 1e4))
                ? converted.toExponential(2)
                : Number(converted.toFixed(4)).toString();
            }
          }
        });
      });
    }

    applyCombinedFilters() {
      const filterIndices = Object.keys(this.activeFilters);
      this.table.querySelectorAll("tbody tr").forEach(tr => {
        let isVisible = true;
        for (const colIdx of filterIndices) {
          const targetVal = this.activeFilters[colIdx];
          if (targetVal !== "") {
            const cell = tr.children[colIdx];
            const cellVal = cell ? cell.textContent.trim() : "";
            if (cellVal !== targetVal) {
              isVisible = false;
              break;
            }
          }
        }
        tr.style.display = isVisible ? "" : "none";
      });
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll("table.dynamic-table-target").forEach(table => {
      new DynamicTableController(table);
    });
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
    local headers = parse_csv_line(lines[1])
    local html = { '<div class="dynamic-table-wrapper">' }

    table.insert(html, string.format(
        '  <table class="dynamic-table-target table table-striped table-hover" data-searchable="%s" data-per-page="%s" data-sortable="%s" data-columns="%s">',
        html_escape(searchable or "true"), html_escape(per_page or "15"), html_escape(sortable or "true"), html_escape(pandoc.json.encode(columns_meta or {}))
    ))
    table.insert(html, '    <thead><tr>')
    for _, h in ipairs(headers) do table.insert(html, '        <th>' .. html_escape(trim(h)) .. '</th>') end
    table.insert(html, '    </tr></thead><tbody>')

    for i = 2, #lines do
        local row = parse_csv_line(lines[i])
        table.insert(html, '      <tr>')
        for j = 1, #headers do
            local cell_trimmed = trim(row[j] or "")
            if cell_trimmed == "" then
                table.insert(html, '        <td></td>')
            else
                local num = tonumber(cell_trimmed)
                local display_txt = html_escape(cell_trimmed)
                if num then
                    -- Output explicit float string into data-order for standard HTML5 sorting
                    local order_val = string.format("%.14g", num)
                    table.insert(html, string.format('        <td data-order="%s" data-base-order="%s">%s</td>', order_val, order_val, display_txt))
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