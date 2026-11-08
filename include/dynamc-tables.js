(function () {
  // 1. Run only if dynamic tables exist on this page
  const tables = document.querySelectorAll("table.dynamic-table-target, .dynamic-table table");
  if (!tables.length) return;

  // 2. Inject Simple-DataTables CSS if not already present
  if (!document.querySelector('link[data-dt-style]')) {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.setAttribute("data-dt-style", "true");
    link.href = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css";
    document.head.appendChild(link);
  }

  // 3. Initialize tables once library script is ready
  function init() {
    tables.forEach((table) => {
      if (table.dataset.dtInitialized) return;
      table.dataset.dtInitialized = "true";

      new simpleDatatables.DataTable(table, {
        searchable: true,
        sortable: true,
        fixedHeight: false,
        perPage: 15,
        labels: {
          placeholder: "Search table...",
          perPage: "{select} entries per page",
          noRows: "No entries found",
          info: "Showing {start} to {end} of {rows} entries",
        }
      });
    });
  }

  // 4. Load Simple-DataTables JS library dynamically
  if (window.simpleDatatables) {
    init();
  } else if (!document.querySelector('script[data-dt-script]')) {
    const script = document.createElement("script");
    script.setAttribute("data-dt-script", "true");
    script.src = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js";
    script.onload = init;
    document.head.appendChild(script);
  }
})();