-- =============================================================================
-- Dynamic Plots Lua Filter
-- =============================================================================

local DEFAULTS = {
    height = 480,
    points = 100,
    skip   = 0,
    xscale = "linear",
    yscale = "linear",
    zscale = "linear",
    play   = false
}

local PATHS = {
    filter_rel   = "lua/dynamic%-plots%.lua",
    template_rel = "include/dynamic-plots.html"
}

local MODES  = { lines = true, markers = true, ["lines+markers"] = true }
local SCALES = { linear = true, log = true }

local FUNCTION_KEYS = {
    expr = true, label = true, xrange = true, yrange = true, zrange = true,
    points = true, mode = true, smooth = true
}

local FILE_KEYS = {
    src = true, skip = true, x = true, y = true, z = true,
    param = true, ["param-label"] = true, transform = true, play = true,
    label = true, mode = true, smooth = true
}

local PLOT_KEYS = {
    curves = true, xlabel = true, ylabel = true, zlabel = true,
    xscale = true, yscale = true, zscale = true,
    xrange = true, yrange = true, zrange = true, height = true
}

local has_dynamic_plot = false
local cached_assets_html = nil
local plot_defs = {}

local SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""

-- Loads and caches the client-side Plotly HTML/CSS/JS template
local function load_assets_html()
    if cached_assets_html then return cached_assets_html end

    local html_path = PANDOC_SCRIPT_FILE:gsub(PATHS.filter_rel .. "$", PATHS.template_rel)
    local file = io.open(html_path, "r")
    if not file then
        error("[dynamic-plots.lua] Error: Cannot open template at '" .. html_path .. "'. Check file path.")
    end

    cached_assets_html = file:read("*a")
    file:close()
    return cached_assets_html
end

-- Trims leading and trailing whitespace
local function trim(s)
    return s and s:match("^%s*(.-)%s*$") or ""
end

-- Escapes special HTML characters for safe attribute injection
local function html_escape(s)
    return s and (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) or ""
end

-- Opens a data file relative to working directory, filter directory, or input document
local function open_data_file(src)
    local file = io.open(src, "r")
    if file then return file end

    if SCRIPT_DIR ~= "" then
        file = io.open(SCRIPT_DIR .. "../" .. src, "r")
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
local function stringify_inline_with_math(inline)
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
            table.insert(inner, stringify_inline_with_math(child))
        end
        return q_char .. table.concat(inner) .. q_char
    elseif inline.c or inline.content then
        local children = inline.content or inline.c
        if type(children) == "table" then
            local res = {}
            for _, child in ipairs(children) do
                table.insert(res, stringify_inline_with_math(child))
            end
            return table.concat(res)
        end
    end

    return pandoc.utils.stringify(inline)
end

-- Extracts logical configuration lines from a Pandoc Div block
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
                else
                    table.insert(current, stringify_inline_with_math(inline))
                end
            end
            local final = trim(table.concat(current))
            if final ~= "" then table.insert(lines, final) end
        end
    end
    return lines
end

-- Parses key-value lines and enforces allowed and required key schemas
local function parse_kv(lines, allowed_keys, required_keys, context)
    local kv = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^([%w_%-]+)%s*:%s*(.+)$")
        if not k then
            error("[dynamic-plots.lua] Error: Invalid line in " .. context .. " (expected 'key: value'): " .. line)
        end
        k = k:lower()
        if not allowed_keys[k] then
            error("[dynamic-plots.lua] Error: Unknown key '" .. k .. "' in " .. context)
        end
        if kv[k] ~= nil then
            error("[dynamic-plots.lua] Error: Duplicate key '" .. k .. "' in " .. context)
        end
        kv[k] = trim(v)
    end

    for _, req in ipairs(required_keys) do
        if not kv[req] or kv[req] == "" then
            error("[dynamic-plots.lua] Error: Missing required key '" .. req .. "' in " .. context)
        end
    end
    return kv
end

-- Parses a boolean option string ('true' or 'false')
local function parse_bool(val, key, context)
    if val == nil then return nil end
    local lower = val:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end
    error("[dynamic-plots.lua] Error: Key '" .. key .. "' in " .. context .. " must be 'true' or 'false' (got '" .. val .. "')")
end

-- Parses an integer option string with a lower bound
local function parse_int(val, key, min_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or math.floor(n) ~= n or n < min_val then
        error("[dynamic-plots.lua] Error: Key '" .. key .. "' in " .. context .. " must be an integer >= " .. tostring(min_val) .. " (got '" .. val .. "')")
    end
    return n
end

-- Parses a numeric axis range '[min, max]'
local function parse_range(val, key, context)
    if val == nil then return nil end
    local inner = trim(val:match("^%[?%s*(.-)%s*%]?$"))
    local parts = {}
    for item in inner:gmatch("[^,]+") do
        local num = tonumber(trim(item))
        if not num then
            error("[dynamic-plots.lua] Error: Invalid numeric bound in '" .. key .. "' of " .. context .. ": " .. val)
        end
        table.insert(parts, num)
    end
    if #parts ~= 2 or parts[1] >= parts[2] then
        error("[dynamic-plots.lua] Error: Key '" .. key .. "' in " .. context .. " must be '[min, max]' with min < max (got '" .. val .. "')")
    end
    return parts
end

-- Validates an option value against a set of allowed enum keys
local function parse_enum(val, key, valid_map, context)
    if val == nil then return nil end
    if not valid_map[val] then
        error("[dynamic-plots.lua] Error: Invalid value '" .. val .. "' for '" .. key .. "' in " .. context)
    end
    return val
end

-- Reads a comma-, tab-, or whitespace-delimited numeric matrix after stripping comments and skipped lines
local function read_numeric_matrix(src, skip, context)
    local file = open_data_file(src)
    if not file then
        error("[dynamic-plots.lua] Error: Cannot open data file at '" .. src .. "' in " .. context .. ". Check file path.")
    end

    local rows = {}
    local skipped = 0
    local expected_cols = nil
    local line_num = 0

    for line in file:lines() do
        line_num = line_num + 1
        local trimmed = trim(line:gsub("\r$", ""))
        if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%%") and not trimmed:match("^//") then
            if skipped < skip then
                skipped = skipped + 1
            else
                local sep = trimmed:find(",") and "[^,]+" or "%S+"
                local row = {}
                for tok in trimmed:gmatch(sep) do
                    local clean = trim(tok)
                    local num = tonumber(clean)
                    if not num then
                        file:close()
                        error(string.format(
                            "[dynamic-plots.lua] Error: Non-numeric value '%s' at line %d of '%s' in %s (use 'skip: N' to skip header rows)",
                            clean, line_num, src, context
                        ))
                    end
                    table.insert(row, num)
                end
                if #row > 0 then
                    if expected_cols == nil then
                        expected_cols = #row
                    elseif #row ~= expected_cols then
                        file:close()
                        error(string.format(
                            "[dynamic-plots.lua] Error: Inconsistent column count at line %d of '%s' in %s (expected %d, got %d)",
                            line_num, src, context, expected_cols, #row
                        ))
                    end
                    table.insert(rows, row)
                end
            end
        end
    end
    file:close()

    if #rows == 0 then
        error("[dynamic-plots.lua] Error: No numeric data rows found in '" .. src .. "' for " .. context)
    end
    return rows
end

-- Registers an analytical function definition block
local function register_function_def(el)
    local id = trim(el.identifier)
    if id == "" then
        error("[dynamic-plots.lua] Error: '.plot-function' block requires an 'id' attribute (e.g. ::: {.plot-function id=\"f1\"})")
    end
    local context = ".plot-function#" .. id
    local kv = parse_kv(extract_lines_from_div(el), FUNCTION_KEYS, { "expr" }, context)

    table.insert(plot_defs, {
        kind   = "function",
        id     = id,
        expr   = kv.expr,
        label  = kv.label or id,
        xrange = parse_range(kv.xrange, "xrange", context),
        yrange = parse_range(kv.yrange, "yrange", context),
        zrange = parse_range(kv.zrange, "zrange", context),
        points = parse_int(kv.points, "points", 2, context),
        mode   = parse_enum(kv.mode, "mode", MODES, context) or "lines",
        smooth = parse_bool(kv.smooth, "smooth", context)
    })
    has_dynamic_plot = true
    return {}
end

-- Registers a file-backed curve or parameter-sweep definition block
local function register_file_def(el)
    local id = trim(el.identifier)
    if id == "" then
        error("[dynamic-plots.lua] Error: '.plot-file' block requires an 'id' attribute (e.g. ::: {.plot-file id=\"data1\"})")
    end
    local context = ".plot-file#" .. id
    local kv = parse_kv(extract_lines_from_div(el), FILE_KEYS, { "src", "x", "y" }, context)

    if kv.param ~= nil then
        if kv.z ~= nil then
            error("[dynamic-plots.lua] Error: Key 'z' is not allowed in parameter-sweep mode in " .. context)
        end
    else
        for _, sweep_only in ipairs({ "transform", "param-label", "play" }) do
            if kv[sweep_only] ~= nil then
                error("[dynamic-plots.lua] Error: Key '" .. sweep_only .. "' requires 'param' in " .. context)
            end
        end
    end

    local skip = parse_int(kv.skip, "skip", 0, context) or DEFAULTS.skip
    local rows = read_numeric_matrix(kv.src, skip, context)

    table.insert(plot_defs, {
        kind       = "file",
        id         = id,
        rows       = rows,
        x          = kv.x,
        y          = kv.y,
        z          = kv.z,
        param      = kv.param,
        paramLabel = kv["param-label"] or "Parameter",
        transform  = kv.transform,
        play       = parse_bool(kv.play, "play", context) or DEFAULTS.play,
        label      = kv.label or id,
        mode       = parse_enum(kv.mode, "mode", MODES, context) or "lines+markers",
        smooth     = parse_bool(kv.smooth, "smooth", context) or false
    })
    has_dynamic_plot = true
    return {}
end

-- Builds the HTML mount container for a dynamic-plot canvas
local function render_plot_canvas(el)
    local id = trim(el.identifier)
    local context = (id ~= "") and (".dynamic-plot#" .. id) or ".dynamic-plot"
    local kv = parse_kv(extract_lines_from_div(el), PLOT_KEYS, { "curves" }, context)

    local curves = {}
    for item in kv.curves:gmatch("[^,]+") do
        local cid = trim(item)
        if cid ~= "" then table.insert(curves, cid) end
    end
    if #curves == 0 then
        error("[dynamic-plots.lua] Error: Key 'curves' in " .. context .. " must list at least one curve ID")
    end

    local cfg = {
        curves = curves,
        xlabel = kv.xlabel,
        ylabel = kv.ylabel,
        zlabel = kv.zlabel,
        xscale = parse_enum(kv.xscale, "xscale", SCALES, context) or DEFAULTS.xscale,
        yscale = parse_enum(kv.yscale, "yscale", SCALES, context) or DEFAULTS.yscale,
        zscale = parse_enum(kv.zscale, "zscale", SCALES, context) or DEFAULTS.zscale,
        xrange = parse_range(kv.xrange, "xrange", context),
        yrange = parse_range(kv.yrange, "yrange", context),
        zrange = parse_range(kv.zrange, "zrange", context),
        height = parse_int(kv.height, "height", 200, context) or DEFAULTS.height
    }

    has_dynamic_plot = true
    local id_attr = (id ~= "") and string.format(' id="%s"', html_escape(id)) or ""
    local html = string.format(
        '<div%s class="dynamic-plot-wrap" data-plot-config="%s"></div>',
        id_attr,
        html_escape(pandoc.json.encode(cfg))
    )
    return pandoc.RawBlock("html", html)
end

-- Detects malformed fenced divs that Pandoc left as raw paragraphs (e.g. missing blank line or space after ':::')
function Para(p)
    local txt = trim(pandoc.utils.stringify(p))
    if txt:match(":::%s*{%.plot%-function") or txt:match(":::%s*{%.plot%-file") or txt:match(":::%s*{%.dynamic%-plot") then
        error("[dynamic-plots.lua] Error: Malformed fenced block (ensure a blank line before ':::' and a space after ':::'): " .. txt)
    end
    return nil
end

-- Pandoc filter hook for '.plot-function', '.plot-file', and '.dynamic-plot' fenced divs
function Div(el)
    if el.classes:includes("plot-function") then
        return register_function_def(el)
    elseif el.classes:includes("plot-file") then
        return register_file_def(el)
    elseif el.classes:includes("dynamic-plot") then
        return render_plot_canvas(el)
    end
    return nil
end

-- Pandoc document hook: injects serialized plot definitions and client assets once per page
function Pandoc(doc)
    if not has_dynamic_plot then
        return doc
    end

    for _, def in ipairs(plot_defs) do
        local safe_json = pandoc.json.encode(def):gsub("</script>", "<\\/script>")
        local tag = string.format(
            '<script type="application/json" class="dynamic-plot-def" data-id="%s">%s</script>',
            html_escape(def.id),
            safe_json
        )
        table.insert(doc.blocks, pandoc.RawBlock("html", tag))
    end

    table.insert(doc.blocks, pandoc.RawBlock("html", load_assets_html()))
    has_dynamic_plot = false
    plot_defs = {}
    return doc
end