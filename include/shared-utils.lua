-- =============================================================================
-- Shared Quarto Utilities
-- =============================================================================

local U = {}

U._file_cache = {}
U._math_injected = setmetatable({}, { __mode = "k" })

local MATH_RENDERER_SCRIPT = [[
<script>
window.MathRenderer = window.MathRenderer || {
  cache: new Map(),
  readyPromise: null,
  queue: Promise.resolve(),

  normalize(str) {
    if (str === null || str === undefined || str === "") return "";
    return String(str)
      .replace(/(^|[^\\])\$\$([\s\S]+?)\$\$/g, "$1\\[$2\\]")
      .replace(/(^|[^\\])\$([^$\n]+?)\$/g, "$1\\($2\\)");
  },

  waitForEngine() {
    if (this.readyPromise) return this.readyPromise;
    const hasMathScript = Boolean(
      window.MathJax ||
      typeof renderMathInElement === "function" ||
      document.querySelector('script[src*="mathjax" i], script[src*="katex" i]')
    );
    if (!hasMathScript) return (this.readyPromise = Promise.resolve("none"));

    this.readyPromise = new Promise((resolve) => {
      let attempts = 0;
      const check = () => {
        if (window.MathJax?.startup?.promise) {
          window.MathJax.startup.promise.then(() => resolve("mathjax")).catch(() => resolve("none"));
        } else if (typeof window.MathJax?.typesetPromise === "function") {
          resolve("mathjax");
        } else if (typeof renderMathInElement === "function") {
          resolve("katex");
        } else if (attempts++ > 150) {
          resolve("none");
        } else {
          setTimeout(check, 20);
        }
      };
      check();
    });
    return this.readyPromise;
  },

  prepare(strings) {
    this.queue = this.queue.then(() => this._renderBatch(strings));
    return this.queue;
  },

  async _renderBatch(strings) {
    const normalized = strings
      .filter((s) => s !== null && s !== undefined && s !== "")
      .map((s) => this.normalize(s));
    const uncached = [...new Set(normalized)].filter((s) => !this.cache.has(s));
    if (uncached.length === 0) return;

    const engine = await this.waitForEngine();
    if (engine === "none") {
      uncached.forEach((s) => this.cache.set(s, s));
      return;
    }

    const sandbox = document.createElement("div");
    sandbox.style.cssText = "position:absolute;left:-9999px;top:-9999px;visibility:hidden;pointer-events:none;";
    const fragment = document.createDocumentFragment();
    const items = uncached.map((str) => {
      const span = document.createElement("span");
      span.textContent = str;
      fragment.appendChild(span);
      return { str, span };
    });
    sandbox.appendChild(fragment);
    document.body.appendChild(sandbox);

    try {
      if (engine === "mathjax") {
        await window.MathJax.typesetPromise([sandbox]);
      } else if (engine === "katex") {
        items.forEach(({ span }) => {
          renderMathInElement(span, {
            delimiters: [
              { left: "$$", right: "$$", display: true },
              { left: "\\(", right: "\\)", inline: true },
              { left: "\\[", right: "\\]", display: true },
              { left: "$", right: "$", inline: true }
            ],
            throwOnError: false
          });
        });
      }
      items.forEach(({ str, span }) => this.cache.set(str, span.innerHTML));
    } finally {
      sandbox.remove();
    }
  },

  get(str) {
    const norm = this.normalize(str);
    return norm === "" ? "" : (this.cache.get(norm) ?? norm);
  }
};
</script>]]

-- Resolves the directory of the calling feature filter
local function resolve_caller_dir(explicit_dir)
    if explicit_dir and explicit_dir ~= "" then
        return explicit_dir
    end
    if debug and debug.getinfo then
        local info = debug.getinfo(3, "S")
        local src = info and info.source and info.source:match("^@(.*[/\\])")
        if src then return src end
    end
    return (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""
end

-- Trims leading and trailing whitespace
function U.trim(s)
    return s and s:match("^%s*(.-)%s*$") or ""
end

-- Escapes special HTML characters for safe attribute injection
function U.html_escape(s)
    return s and (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) or ""
end

-- Checks whether a string contains inline or display LaTeX delimiters
function U.has_math(s)
    return type(s) == "string" and (s:find("\\%(") ~= nil or s:find("\\%[") ~= nil or s:find("%$") ~= nil)
end

-- Reads and caches a text asset from disk
function U.read_asset(path, tag)
    if U._file_cache[path] then
        return U._file_cache[path]
    end
    local file = io.open(path, "r")
    if not file then
        error(string.format("[%s] Error: Cannot open asset at '%s'. Check file path.", tag or "shared-utils", path))
    end
    local content = file:read("*a")
    file:close()
    U._file_cache[path] = content
    return content
end

-- Opens a data file relative to working directory, project root (from include/<feature>/), or active document
function U.open_data_file(src, script_dir)
    local file = io.open(src, "r")
    if file then return file end

    local dir = resolve_caller_dir(script_dir)
    if dir ~= "" then
        file = io.open(dir .. "../../" .. src, "r")
        if file then return file end
    end

    if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
        local doc_dir = PANDOC_STATE.input_files[1]:match("(.*[/\\])")
        if doc_dir then
            file = io.open(doc_dir .. src, "r")
            if file then return file end
        end
    end

    return nil
end

-- Serializes Pandoc inline nodes while preserving LaTeX math delimiters and quotes
function U.stringify_inline_with_math(inline)
    if not inline then return "" end

    if inline.t == "Math" then
        local is_display = inline.mathtype == "DisplayMath" or inline.mathtype == pandoc.DisplayMath
        return is_display and ("\\[" .. inline.text .. "\\]") or ("\\(" .. inline.text .. "\\)")
    end

    local children = inline.content or inline.c
    if type(children) == "table" then
        local res = {}
        for _, child in ipairs(children) do
            table.insert(res, U.stringify_inline_with_math(child))
        end
        local joined = table.concat(res)
        if inline.t == "Quoted" then
            local q = (inline.quotetype == "SingleQuote" or inline.quotetype == pandoc.SingleQuote) and "'" or '"'
            return q .. joined .. q
        end
        return joined
    end

    return pandoc.utils.stringify(inline)
end

-- Extracts logical configuration lines from a Pandoc Div block
function U.extract_lines_from_div(el)
    local lines = {}
    for _, block in ipairs(el.content) do
        if block.content then
            local current = {}
            for _, inline in ipairs(block.content) do
                if inline.t == "SoftBreak" or inline.t == "LineBreak" then
                    local l = U.trim(table.concat(current))
                    if l ~= "" then table.insert(lines, l) end
                    current = {}
                else
                    table.insert(current, U.stringify_inline_with_math(inline))
                end
            end
            local final = U.trim(table.concat(current))
            if final ~= "" then table.insert(lines, final) end
        end
    end
    return lines
end

-- Emits a hidden native Math node so Quarto loads its configured MathJax/KaTeX engine
function U.ensure_quarto_math(doc)
    table.insert(doc.blocks, pandoc.Plain({
        pandoc.Span({ pandoc.Math("InlineMath", "") }, pandoc.Attr("", {}, { style = "display:none;" }))
    }))
end

-- Injects HTML into a Quarto document location ('in-header' or 'after-body')
function U.inject_html(doc, location, html)
    if quarto and quarto.doc and quarto.doc.include_text then
        quarto.doc.include_text(location, html)
    else
        table.insert(doc.blocks, pandoc.RawBlock("html", html))
    end
end

-- Injects shared MathRenderer once and appends HTML/JS at the end of the document body
function U.inject_after_body(doc, html)
    local payload = html
    if not U._math_injected[doc] then
        U._math_injected[doc] = true
        payload = MATH_RENDERER_SCRIPT .. "\n" .. html
    end
    U.inject_html(doc, "after-body", payload)
end

-- Injects a widget's co-located <name>.css (in-header) and/or <name>.js (after-body)
function U.inject_widget(doc, name, script_dir, opts)
    opts = opts or {}
    local dir = resolve_caller_dir(script_dir)
    local css_path = dir .. name .. ".css"
    local js_path  = dir .. name .. ".js"

    local has_css = io.open(css_path, "r")
    if has_css then has_css:close() end
    local has_js = io.open(js_path, "r")
    if has_js then has_js:close() end

    if not has_css and not has_js then
        error(string.format("[%s] Error: No '%s.css' or '%s.js' found in '%s'", name, name, name, dir))
    end

    if opts.head or has_css then
        local head_parts = {}
        if opts.head then table.insert(head_parts, opts.head) end
        if has_css then
            table.insert(head_parts, "<style>\n" .. U.read_asset(css_path, name) .. "\n</style>")
        end
        U.inject_html(doc, "in-header", table.concat(head_parts, "\n"))
    end

    if opts.body_prefix or has_js then
        local body_parts = {}
        if opts.body_prefix then table.insert(body_parts, opts.body_prefix) end
        if has_js then
            table.insert(body_parts, "<script>\n" .. U.read_asset(js_path, name) .. "\n</script>")
        end
        U.inject_after_body(doc, table.concat(body_parts, "\n"))
    end
end

return U