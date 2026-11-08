document.addEventListener("DOMContentLoaded", function () {
  const tables = document.querySelectorAll("table.dynamic-table-target, .dynamic-table table");
  if (tables.length === 0) return; // Exit if no dynamic tables exist on this page

  // 1. Inject Simple-DataTables CSS
  if (!document.querySelector('link[href*="simple-datatables"]')) {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/style.css";
    document.head.appendChild(link);
  }

  // 2. Helper to dynamically load script
  function loadSimpleDataTables(callback) {
    if (window.simpleDatatables) {
      callback();
      return;
    }
    const script = document.createElement("script");
    script.src = "https://cdn.jsdelivr.net/npm/simple-datatables@latest/dist/umd/simple-datatables.js";
    script.onload = callback;
    document.head.appendChild(script);
  }

  // 3. Load script & initialize tables
  loadSimpleDataTables(() => {
    tables.forEach((table) => {
      new simpleDatatables.DataTable(table, {
        searchable: true,
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
  });
});