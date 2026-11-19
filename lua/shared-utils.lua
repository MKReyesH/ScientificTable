-- =============================================================================
-- Shared Quarto Widget Utilities
-- =============================================================================

local U = {}

U.SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""
U._template_cache = {}
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

-- Loads and caches a widget HTML/CSS/JS template relative to the calling filter
function U.load_template(filter_rel, template_rel, tag, script_file)
    local base_script = script_file or PANDOC_SCRIPT_FILE or ""
    local html_path = base_script:gsub(filter_rel .. "$", template_rel)
    if U._template_cache[html_path] then
        return U._template_cache[html_path]
    end

    local file = io.open(html_path, "r")
    if not file then
        error(string.format("[%s] Error: Cannot open template at '%s'. Check file path.", tag, html_path))
    end

    local content = file:read("*a")
    file:close()
    U._template_cache[html_path] = content
    return content
end

-- Opens a data file relative to working directory, filter parent directory, or input document
function U.open_data_file(src, script_dir)
    local file = io.open(src, "r")
    if file then return file end

    local dir = script_dir or U.SCRIPT_DIR
    if dir ~= "" then
        file = io.open(dir .. "../" .. src, "r")
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
        if inline.mathtype == "DisplayMath" or inline.mathtype == pandoc.DisplayMath then
            return "\\[" .. inline.text .. "\\]"
        end
        return "\\(" .. inline.text .. "\\)"
    elseif inline.t == "Quoted" then
        local q_char = (inline.quotetype == "SingleQuote" or inline.quotetype == pandoc.SingleQuote) and "'" or '"'
        local inner = {}
        for _, child in ipairs(inline.content or inline.c or {}) do
            table.insert(inner, U.stringify_inline_with_math(child))
        end
        return q_char .. table.concat(inner) .. q_char
    elseif inline.c or inline.content then
        local children = inline.content or inline.c
        if type(children) == "table" then
            local res = {}
            for _, child in ipairs(children) do
                table.insert(res, U.stringify_inline_with_math(child))
            end
            return table.concat(res)
        end
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

-- Injects shared MathRenderer once and appends widget HTML/CSS/JS assets at the end of the document body
function U.inject_after_body(doc, html)
    local payload = html
    if not U._math_injected[doc] then
        U._math_injected[doc] = true
        payload = MATH_RENDERER_SCRIPT .. "\n" .. html
    end

    if quarto and quarto.doc and quarto.doc.include_text then
        quarto.doc.include_text("after-body", payload)
    else
        table.insert(doc.blocks, pandoc.RawBlock("html", payload))
    end
end

return U