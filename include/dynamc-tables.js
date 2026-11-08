(function () {
  function initDynamicTables() {
    const tables = document.querySelectorAll("table.dynamic-table-target, .dynamic-table table");
    if (tables.length === 0) return;

    // 1. Inject Simple-DataTables CSS if not already present
    if (!document.querySelector('link[href*="simple-datatables"]')) {
      const link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css";
      document.head.appendChild(link);
    }

    // 2. Instantiate Simple-DataTables on all targets
    function instantiate() {
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

    // 3. Load script if not already present
    if (window.simpleDatatables) {
      instantiate();
    } else {
      const script = document.createElement("script");
      script.src = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js";
      script.onload = instantiate;
      document.head.appendChild(script);
    }
  }

  // Execute immediately if DOM is ready, otherwise wait for event
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initDynamicTables);
  } else {
    initDynamicTables();
  }
})();