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

  // Parses comma- or semicolon-separated citation keys from a cell value
  function parseCitationKeys(raw) {
    if (raw === null || raw === undefined) return [];
    return String(raw)
      .split(/[,;]+/)
      .map(k => k.trim().replace(/^@/, ""))
      .filter(Boolean);
  }

  const highlightTimers = new WeakMap();

  // Temporarily highlights a target bibliography entry when clicked from the table
  function highlightReference(entryEl) {
    if (!entryEl) return;
    clearTimeout(highlightTimers.get(entryEl));
    entryEl.classList.remove("is-highlighted");
    void entryEl.offsetWidth;
    entryEl.classList.add("is-highlighted");

    highlightTimers.set(entryEl, setTimeout(() => {
      entryEl.classList.remove("is-highlighted");
    }, 1600));
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

  // Composable registry of column cell formatters and header controls
  const ColumnFeatures = {
    number: (colDef, colCfg, ctx) => {
      colDef.formatter = (cell) => ctx.formatValue(colCfg, cell.getValue());
    },

    latex: (colDef) => {
      const baseFormatter = colDef.formatter;
      colDef.formatter = (cell, formatterParams, onRendered) => {
        const raw = baseFormatter ? baseFormatter(cell, formatterParams, onRendered) : cell.getValue();
        return MathRenderer.get(raw);
      };
    },

    inspire: (colDef, colCfg, ctx) => {
      colDef.formatter = (cell) => {
        const keys = parseCitationKeys(cell.getValue());
        if (keys.length === 0) return "";
        const frag = document.createDocumentFragment();
        keys.forEach((key, idx) => {
          if (idx > 0) frag.appendChild(document.createTextNode(", "));
          const targetId = ctx.refTargetIds.get(key);
          if (targetId) {
            const label = ctx.refLabels.get(key);
            const link = document.createElement("a");
            link.href = `#${targetId}`;
            link.textContent = label ? `${label} ${key}` : key;
            link.addEventListener("click", () => highlightReference(ctx.refEntries.get(key)));
            frag.appendChild(link);
          } else {
            frag.appendChild(document.createTextNode(key));
          }
        });
        return frag;
      };
    },

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

  let tableInstanceCounter = 0;

  // Controller managing Tabulator lifecycle, math pre-rendering, and live bibliography filtering
  class TabulatorTableController {
    constructor(container) {
      this.instanceId = ++tableInstanceCounter;
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

      this.inspireFields = this.columnConfigs.filter(c => c.inspire).map(c => c.field);
      this.refsWrap = (this.inspireFields.length > 0 && container.nextElementSibling?.classList.contains("dynamic-table-refs"))
        ? container.nextElementSibling
        : null;
      this.refEntries = new Map();
      this.refTargetIds = new Map();
      this.refLabels = new Map();
      this.rowKeysCache = new WeakMap();

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

    // Relocates Pandoc-rendered references below the table using native Quarto bibliography classes
    initBibliography() {
      if (!this.refsWrap || this.inspireFields.length === 0) return;

      const allKeys = [];
      const seen = new Set();
      this.rows.forEach(row => {
        const rowKeys = [];
        this.inspireFields.forEach(field => {
          parseCitationKeys(row[field]).forEach(key => {
            rowKeys.push(key);
            if (!seen.has(key)) {
              seen.add(key);
              allKeys.push(key);
            }
          });
        });
        this.rowKeysCache.set(row, rowKeys);
      });

      const globalRefs = document.getElementById("refs");
      const globalHeading = document.querySelector("#quarto-bibliography .quarto-appendix-heading");

      const heading = document.createElement("h4");
      heading.textContent = globalHeading?.textContent.trim() || "References";
      this.refsWrap.appendChild(heading);

      const listContainer = document.createElement("div");
      listContainer.className = globalRefs?.className || "references csl-bib-body hanging-indent";
      listContainer.setAttribute("role", "list");
      if (globalRefs?.dataset.entrySpacing !== undefined) {
        listContainer.dataset.entrySpacing = globalRefs.dataset.entrySpacing;
      }
      this.refsWrap.appendChild(listContainer);

      allKeys.forEach(key => {
        const sourceEl = document.getElementById(`ref-${key}`);
        if (!sourceEl) return;

        const labelText = sourceEl.querySelector(".csl-left-margin")?.textContent.trim() || "";
        if (labelText) this.refLabels.set(key, labelText);

        let entryEl;
        if (sourceEl.closest(".dynamic-table-refs")) {
          const scopedId = `ref-t${this.instanceId}-${key}`;
          entryEl = sourceEl.cloneNode(true);
          entryEl.id = scopedId;
          entryEl.classList.remove("is-highlighted");
          entryEl.style.display = "";
          this.refTargetIds.set(key, scopedId);
        } else {
          entryEl = sourceEl;
          this.refTargetIds.set(key, `ref-${key}`);
        }

        listContainer.appendChild(entryEl);
        this.refEntries.set(key, entryEl);
      });

      if (globalRefs && !globalRefs.querySelector(".csl-entry")) {
        globalRefs.style.display = "none";
        const quartoAppendix = globalRefs.closest("#quarto-appendix");
        if (quartoAppendix) {
          const hasOtherEntries = Array.from(quartoAppendix.querySelectorAll(".csl-entry"))
            .some(el => !el.closest(".dynamic-table-refs"));
          if (!hasOtherEntries) {
            quartoAppendix.style.display = "none";
          }
        }
      }
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

    // Updates reference visibility to match currently visible table rows
    syncBibliography() {
      if (!this.refsWrap || this.refEntries.size === 0 || !this.table) return;

      const visibleKeys = new Set();
      this.table.getRows("visible").forEach(row => {
        const keys = this.rowKeysCache.get(row.getData());
        if (keys) {
          for (let i = 0; i < keys.length; i++) visibleKeys.add(keys[i]);
        }
      });

      let visibleCount = 0;
      this.refEntries.forEach((entryEl, key) => {
        const show = visibleKeys.has(key);
        entryEl.style.display = show ? "" : "none";
        if (show) visibleCount++;
      });

      this.refsWrap.style.display = visibleCount > 0 ? "" : "none";
    }

    // Synchronizes pagination visibility, bibliography filtering, and multi-line row borders
    syncUI() {
      this.syncPagination();
      this.syncBibliography();
      this.table?.getRows("visible").forEach(row => row.normalizeHeight(true));
    }

    // Initializes math cache, bibliography bindings, Tabulator instance, and search filter
    async init() {
      await MathRenderer.prepare(this.collectInitialLatexStrings());
      this.container.innerHTML = "";
      this.initBibliography();

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
          ColumnFeatures.inspire(colDef, colCfg, this);
        } else {
          if (colCfg.type === "number") ColumnFeatures.number(colDef, colCfg, this);
          if (colCfg.isLatex) ColumnFeatures.latex(colDef, colCfg, this);
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

      this.table.on("tableBuilt", () => this.syncUI());
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

  // Mounts Tabulator controllers on all dynamic table containers
  function initDynamicTables() {
    document.querySelectorAll(".tabulator-container-wrap").forEach(el => {
      if (!el.dataset.initialized) {
        el.dataset.initialized = "true";
        new TabulatorTableController(el);
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initDynamicTables);
  } else {
    initDynamicTables();
  }
})();