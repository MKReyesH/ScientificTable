(() => {
  if (window.__quartoThemeToggleInit) return;
  window.__quartoThemeToggleInit = true;

  const QUARTO_KEY = "quarto-color-scheme";
  const LABELS = {
    auto: "Theme: Automatic (System)",
    light: "Theme: Light",
    dark: "Theme: Dark"
  };

  const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const nativeToggle = window.quartoToggleColorScheme;

  const storage = {
    get() { try { return localStorage.getItem(QUARTO_KEY); } catch { return null; } },
    set(val) { try { localStorage.setItem(QUARTO_KEY, val); } catch {} },
    remove() { try { localStorage.removeItem(QUARTO_KEY); } catch {} }
  };

  const isPageDark = () => document.body.classList.contains("quarto-dark");

  const getMode = () => {
    const val = storage.get();
    return val === "alternate" ? "dark" : val === "default" ? "light" : "auto";
  };

  const syncVisual = (wantDark) => {
    if (typeof nativeToggle === "function") {
      if (isPageDark() !== wantDark) nativeToggle();
    } else {
      document.documentElement.setAttribute("data-bs-theme", wantDark ? "dark" : "light");
    }
  };

  const syncButton = (mode) => {
    document.querySelectorAll(".quarto-color-scheme-toggle").forEach((el) => {
      el.dataset.themeMode = mode;
      el.setAttribute("title", LABELS[mode]);
      el.setAttribute("aria-label", LABELS[mode]);
    });
  };

  const applyMode = (mode) => {
    if (mode === "dark") {
      syncVisual(true);
      storage.set("alternate");
    } else if (mode === "light") {
      syncVisual(false);
      storage.set("default");
    } else {
      syncVisual(mediaQuery.matches);
      storage.remove();
    }
    syncButton(mode);
  };

  window.quartoToggleColorScheme = () => {
    const current = getMode();
    const next = current === "auto"
      ? (isPageDark() ? "light" : "dark")
      : current === "dark"
        ? (mediaQuery.matches ? "auto" : "light")
        : (!mediaQuery.matches ? "auto" : "dark");
    applyMode(next);
  };

  mediaQuery.addEventListener("change", () => {
    if (getMode() === "auto") applyMode("auto");
  });

  window.addEventListener("storage", (e) => {
    if (e.key === QUARTO_KEY) applyMode(getMode());
  });

  const mountSidebarToggle = () => {
    const tools = document.querySelector("#quarto-sidebar .sidebar-header .sidebar-tools-main");
    const searchWrap = document.querySelector("#quarto-sidebar .sidebar-search");
    if (tools && searchWrap && !searchWrap.contains(tools)) {
      searchWrap.classList.add("has-theme-toggle");
      searchWrap.appendChild(tools);
    }
  };

  const init = () => {
    mountSidebarToggle();
    applyMode(getMode());
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();