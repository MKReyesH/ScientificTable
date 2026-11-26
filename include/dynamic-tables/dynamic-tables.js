(() => {
  if (window.__quartoDynamicTablesInit) return;
  window.__quartoDynamicTablesInit = true;

  // Scales a numeric value and formats extreme magnitudes in exponential notation
  function formatScaledNumber(val, factor = 1) {
    if (val === null || val === undefined || val === "") return "";
    const num = Number(val);
    if (isNaN(num)) return String(val);

    const converted = num * factor;
    const abs = Math.abs(converted);
    return (abs > 0 && (abs < 1e-3 || abs >= 1e4))
      ? converted.toExponential(2)
      : Number(converted.toFixed(4)).toString();
  }

  // Formats a scaled number as an inline LaTeX math string
  function toLatexNumberString(val, factor = 1) {
    if (val === null || val === undefined || val === "") return "";
    if (isNaN(Number(val))) return String(val);
    const formatted = formatScaledNumber(val, factor);
    if (formatted.includes("e")) {
      const [mantissa, exponent] = formatted.split("e");
      return `$${mantissa} \\times 10^{${parseInt(exponent, 10)}}$`;
    }
    return `$${formatted}$`;
  }

  // Builds a unified Bootstrap-styled select control for header filters and unit switchers
  function createSelectMenu(options, onChange, selectedValue = "") {
    const select = document.createElement("select");
    select.className = "form-select form-select-sm tabulator-unified-select";

    options.forEach(opt => {
      const optionEl = document.createElement("option");
      const val = typeof opt === "object" ? opt.value : opt;
      const lbl = typeof opt === "object" ? opt.label : opt;
      optionEl.value = val;
      optionEl.textContent = lbl;
      if (String(val) === String(selectedValue)) optionEl.selected = true;
      select.appendChild(optionEl);
    });

    select.addEventListener("click", e => e.stopPropagation());
    select.addEventListener("change", e => onChange(e.target.value));
    return select;
  }

  // Header controls composed with the column's display formatter.
  const ColumnFeatures = {
    dropdown: (colDef, colCfg, ctx) => {
      const rawValues = [...new Set(ctx.rows.map(r => r[colCfg.field]).filter(v => v !== null && v !== undefined && v !== ""))].sort();
      const options = [{ label: "All", value: "" }, ...rawValues.map(v => ({ label: v, value: v }))];
      colDef.headerFilter = (cell, onRendered, success) => createSelectMenu(options, success);
    },

    units: (colDef, colCfg, ctx) => {
      if (!colCfg.units || !colCfg.map) return;

      colDef.titleFormatter = () => {
        const wrap = document.createElement("div");
        wrap.className = "tabulator-title-wrap";

        const label = document.createElement("span");
        label.className = "fw-bold";
        if (colCfg.isLatex) {
          label.innerHTML = MathRenderer.get(colCfg.name);
        } else {
          label.textContent = colCfg.name;
        }
        wrap.appendChild(label);

        const select = createSelectMenu(
          colCfg.units,
          async (val) => {
            const factor = colCfg.map[val];
            if (factor === undefined) return;
            ctx.unitFactors[colCfg.index] = factor;

            if (colCfg.isLatex) {
              await MathRenderer.prepare(ctx.rows.map(r => ctx.formatValue(colCfg, r[colCfg.field])));
            }
            ctx.table.redraw(true);
          },
          colCfg.units[0]
        );

        wrap.appendChild(select);
        return wrap;
      };
    }
  };

  // Controller managing Tabulator lifecycle and table-specific rendering.
  class TabulatorTableController {
    constructor(container) {
      this.container = container;
      this.headers = JSON.parse(container.dataset.headers || "[]");
      this.rows = JSON.parse(container.dataset.rows || "[]");
      this.perPage = parseInt(container.dataset.perpage || "15", 10);
      this.searchable = container.dataset.searchable !== "false";
      this.sortable = container.dataset.sortable !== "false";

      const rawConfig = JSON.parse(container.dataset.columns || "[]");
      this.unitFactors = {};
      this.columnConfigs = this.headers.map((h, idx) => {
        const cfg = rawConfig.find(c => c.index === idx) || {};
        this.unitFactors[idx] = (cfg.units && cfg.map) ? (cfg.map[cfg.units[0]] ?? 1) : 1;
        return {
          ...cfg,
          index: idx,
          name: cfg.header || h,
          field: "col_" + idx,
          isLatex: Boolean(cfg.latex || cfg.latexnum)
        };
      });

      this.table = null;
      this.init();
    }

    // Computes a cell's pre-LaTeX display string based on column type and active unit factor
    formatValue(colCfg, rawVal) {
      if (colCfg.type === "number") {
        const factor = this.unitFactors[colCfg.index];
        return colCfg.latexnum
          ? toLatexNumberString(rawVal, factor)
          : formatScaledNumber(rawVal, factor);
      }
      return rawVal ?? "";
    }

    // Collects all initial LaTeX strings across headers and cells for batch rendering
    collectInitialLatexStrings() {
      const strings = [];
      this.columnConfigs.forEach(cfg => {
        if (!cfg.isLatex) return;
        strings.push(cfg.name);
        this.rows.forEach(r => strings.push(this.formatValue(cfg, r[cfg.field])));
      });
      return strings;
    }

    // Hides the pagination footer when all active rows fit within the current page size
    syncPagination() {
      if (!this.table) return;
      const footer = this.table.element?.querySelector(".tabulator-footer");
      if (!footer) return;

      const activeRows = this.table.getDataCount("active");
      const pageSize = this.table.getPageSize();
      footer.style.display = activeRows > pageSize ? "" : "none";
    }

    // Synchronizes pagination visibility and multi-line row borders
    syncUI() {
      this.syncPagination();
      this.table?.getRows("visible").forEach(row => row.normalizeHeight());
    }

    // Initializes math cache, Tabulator instance, and search filter
    async init() {
      const latexStrings = this.collectInitialLatexStrings();
      if (latexStrings.length > 0) {
        await MathRenderer.prepare(latexStrings);
      }
      const source = this.container.nextElementSibling?.querySelector(":scope > .dynamic-table-citations");
      const citations = new Map(Array.from(source?.children ?? [], node => [node.dataset.citationCell, node]));
      source?.remove();

      let searchInput = null;
      if (this.searchable) {
        const topBar = document.createElement("div");
        topBar.className = "d-flex justify-content-between align-items-center mb-2 flex-wrap gap-2";
        topBar.innerHTML = '<input type="text" class="form-control form-control-sm tabulator-search-input" style="width:220px;" placeholder="Search table...">';
        this.container.appendChild(topBar);
        searchInput = topBar.querySelector(".tabulator-search-input");
      }

      const tableDiv = document.createElement("div");
      this.container.appendChild(tableDiv);

      const columns = this.columnConfigs.map(colCfg => {
        const colDef = {
          title: colCfg.name,
          field: colCfg.field,
          maxWidth: 320,
          headerSort: colCfg.sortable !== undefined ? colCfg.sortable : this.sortable,
          sorter: colCfg.type === "number" ? "number" : "string",
          sorterParams: { alignEmptyValues: "bottom" },
          headerHozAlign: "left"
        };

        if (colCfg.isLatex && !colCfg.units) {
          colDef.titleFormatter = () => MathRenderer.get(colCfg.name);
        }

        if (colCfg.inspire) {
          colDef.formatter = cell => citations.get(`${cell.getRow().getIndex()}-${colCfg.field}`)
            ?? document.createTextNode(cell.getValue() ?? "");
        } else if (colCfg.isLatex) {
          colDef.formatter = cell => MathRenderer.get(this.formatValue(colCfg, cell.getValue()));
        } else if (colCfg.type === "number") {
          colDef.formatter = cell => this.formatValue(colCfg, cell.getValue());
        }

        if (colCfg.dropdown) ColumnFeatures.dropdown(colDef, colCfg, this);
        if (colCfg.units) ColumnFeatures.units(colDef, colCfg, this);

        return colDef;
      });

      this.table = new Tabulator(tableDiv, {
        data: this.rows,
        columns: columns,
        layout: "fitData",
        renderVertical: "basic",
        responsiveLayout: false,
        pagination: "local",
        paginationSize: this.perPage,
        paginationSizeSelector: [10, 15, 25, 50],
        movableColumns: false
      });

      this.table.on("renderComplete", () => this.syncUI());

      if (searchInput) {
        let searchTimer = null;
        const fields = this.columnConfigs.map(c => c.field);
        const rowSearchIndex = new WeakMap();
        const getRowText = (row) => {
          let text = rowSearchIndex.get(row);
          if (text === undefined) {
            text = fields.map(f => row[f] ?? "").join("\0").toLowerCase();
            rowSearchIndex.set(row, text);
          }
          return text;
        };

        searchInput.addEventListener("input", (e) => {
          clearTimeout(searchTimer);
          const query = e.target.value.toLowerCase().trim();
          searchTimer = setTimeout(() => {
            if (query === "") {
              this.table.clearFilter();
            } else {
              this.table.setFilter(data => getRowText(data).includes(query));
            }
          }, 150);
        });
      }
    }
  }

  function initDynamicTables() {
    document.querySelectorAll(".tabulator-container-wrap").forEach(el => new TabulatorTableController(el));
  }

  if (document.readyState === "loading") {
    // Quarto initializes citations on document before the event bubbles to window.
    window.addEventListener("DOMContentLoaded", initDynamicTables, {once: true});
  } else {
    initDynamicTables();
  }
})();
