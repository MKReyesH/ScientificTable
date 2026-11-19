-- =============================================================================
-- Dynamic Plots Lua Filter
-- =============================================================================

local TAG = "dynamic-plots.lua"
local SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""

local U
do
    local orig_path = package.path
    if SCRIPT_DIR ~= "" then
        package.path = SCRIPT_DIR .. "?.lua;" .. orig_path
    end
    local ok, mod = pcall(require, "shared-utils")
    package.path = orig_path
    if not ok then
        error(string.format("[%s] Error: Required module 'shared-utils.lua' not found in '%s': %s", TAG, SCRIPT_DIR, tostring(mod)))
    end
    U = mod
end

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
local has_plot_math = false
local plot_defs = {}

local function track_math(str)
    if U.has_math(str) then
        has_plot_math = true
    end
end

-- Parses key-value lines and enforces allowed and required key schemas
local function parse_kv(lines, allowed_keys, required_keys, context)
    local kv = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^([%w_%-]+)%s*:%s*(.+)$")
        if not k then
            error(string.format("[%s] Error: Invalid line in %s (expected 'key: value'): %s", TAG, context, line))
        end
        k = k:lower()
        if not allowed_keys[k] then
            error(string.format("[%s] Error: Unknown key '%s' in %s", TAG, k, context))
        end
        if kv[k] ~= nil then
            error(string.format("[%s] Error: Duplicate key '%s' in %s", TAG, k, context))
        end
        kv[k] = U.trim(v)
    end

    for _, req in ipairs(required_keys) do
        if not kv[req] or kv[req] == "" then
            error(string.format("[%s] Error: Missing required key '%s' in %s", TAG, req, context))
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
    error(string.format("[%s] Error: Key '%s' in %s must be 'true' or 'false' (got '%s')", TAG, key, context, val))
end

-- Parses an integer option string with a lower bound
local function parse_int(val, key, min_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or math.floor(n) ~= n or n < min_val then
        error(string.format("[%s] Error: Key '%s' in %s must be an integer >= %d (got '%s')", TAG, key, context, min_val, val))
    end
    return n
end

-- Parses a numeric axis range '[min, max]'
local function parse_range(val, key, context)
    if val == nil then return nil end
    local inner = U.trim(val:match("^%[?%s*(.-)%s*%]?$"))
    local parts = {}
    for item in inner:gmatch("[^,]+") do
        local num = tonumber(U.trim(item))
        if not num then
            error(string.format("[%s] Error: Invalid numeric bound in '%s' of %s: %s", TAG, key, context, val))
        end
        table.insert(parts, num)
    end
    if #parts ~= 2 or parts[1] >= parts[2] then
        error(string.format("[%s] Error: Key '%s' in %s must be '[min, max]' with min < max (got '%s')", TAG, key, context, val))
    end
    return parts
end

-- Validates an option value against a set of allowed enum keys
local function parse_enum(val, key, valid_map, context)
    if val == nil then return nil end
    if not valid_map[val] then
        error(string.format("[%s] Error: Invalid value '%s' for '%s' in %s", TAG, val, key, context))
    end
    return val
end

-- Reads a comma-, tab-, or whitespace-delimited numeric matrix after stripping comments and skipped lines
local function read_numeric_matrix(src, skip, context)
    local file = U.open_data_file(src, SCRIPT_DIR)
    if not file then
        error(string.format("[%s] Error: Cannot open data file at '%s' in %s. Check file path.", TAG, src, context))
    end

    local rows = {}
    local skipped = 0
    local expected_cols = nil
    local line_num = 0

    for line in file:lines() do
        line_num = line_num + 1
        local trimmed = U.trim(line:gsub("\r$", ""))
        if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%%") and not trimmed:match("^//") then
            if skipped < skip then
                skipped = skipped + 1
            else
                local sep = trimmed:find(",") and "[^,]+" or "%S+"
                local row = {}
                for tok in trimmed:gmatch(sep) do
                    local clean = U.trim(tok)
                    local num = tonumber(clean)
                    if not num then
                        file:close()
                        error(string.format(
                            "[%s] Error: Non-numeric value '%s' at line %d of '%s' in %s (use 'skip: N' to skip header rows)",
                            TAG, clean, line_num, src, context
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
                            "[%s] Error: Inconsistent column count at line %d of '%s' in %s (expected %d, got %d)",
                            TAG, line_num, src, context, expected_cols, #row
                        ))
                    end
                    table.insert(rows, row)
                end
            end
        end
    end
    file:close()

    if #rows == 0 then
        error(string.format("[%s] Error: No numeric data rows found in '%s' for %s", TAG, src, context))
    end
    return rows
end

-- Registers an analytical function definition block
local function register_function_def(el)
    local id = U.trim(el.identifier)
    if id == "" then
        error(string.format("[%s] Error: '.plot-function' block requires an 'id' attribute (e.g. ::: {.plot-function id=\"f1\"})", TAG))
    end
    local context = ".plot-function#" .. id
    local kv = parse_kv(U.extract_lines_from_div(el), FUNCTION_KEYS, { "expr" }, context)
    local label = kv.label or id
    track_math(label)

    table.insert(plot_defs, {
        kind   = "function",
        id     = id,
        expr   = kv.expr,
        label  = label,
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
    local id = U.trim(el.identifier)
    if id == "" then
        error(string.format("[%s] Error: '.plot-file' block requires an 'id' attribute (e.g. ::: {.plot-file id=\"data1\"})", TAG))
    end
    local context = ".plot-file#" .. id
    local kv = parse_kv(U.extract_lines_from_div(el), FILE_KEYS, { "src", "x", "y" }, context)

    if kv.param ~= nil then
        if kv.z ~= nil then
            error(string.format("[%s] Error: Key 'z' is not allowed in parameter-sweep mode in %s", TAG, context))
        end
    else
        for _, sweep_only in ipairs({ "transform", "param-label", "play" }) do
            if kv[sweep_only] ~= nil then
                error(string.format("[%s] Error: Key '%s' requires 'param' in %s", TAG, sweep_only, context))
            end
        end
    end

    local skip = parse_int(kv.skip, "skip", 0, context) or DEFAULTS.skip
    local rows = read_numeric_matrix(kv.src, skip, context)
    local label = kv.label or id
    local param_label = kv["param-label"] or "Parameter"
    track_math(label)
    track_math(param_label)

    table.insert(plot_defs, {
        kind       = "file",
        id         = id,
        rows       = rows,
        x          = kv.x,
        y          = kv.y,
        z          = kv.z,
        param      = kv.param,
        paramLabel = param_label,
        transform  = kv.transform,
        play       = parse_bool(kv.play, "play", context) or DEFAULTS.play,
        label      = label,
        mode       = parse_enum(kv.mode, "mode", MODES, context) or "lines+markers",
        smooth     = parse_bool(kv.smooth, "smooth", context) or false
    })
    has_dynamic_plot = true
    return {}
end

-- Builds the HTML mount container for a dynamic-plot canvas
local function render_plot_canvas(el)
    local id = U.trim(el.identifier)
    local context = (id ~= "") and (".dynamic-plot#" .. id) or ".dynamic-plot"
    local kv = parse_kv(U.extract_lines_from_div(el), PLOT_KEYS, { "curves" }, context)

    local curves = {}
    for item in kv.curves:gmatch("[^,]+") do
        local cid = U.trim(item)
        if cid ~= "" then table.insert(curves, cid) end
    end
    if #curves == 0 then
        error(string.format("[%s] Error: Key 'curves' in %s must list at least one curve ID", TAG, context))
    end

    track_math(kv.xlabel)
    track_math(kv.ylabel)
    track_math(kv.zlabel)

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
    local id_attr = (id ~= "") and string.format(' id="%s"', U.html_escape(id)) or ""
    local html = string.format(
        '<div%s class="dynamic-plot-wrap" data-plot-config="%s"></div>',
        id_attr,
        U.html_escape(pandoc.json.encode(cfg))
    )
    return pandoc.RawBlock("html", html)
end

-- Detects malformed fenced divs that Pandoc left as raw paragraphs (e.g. missing blank line or space after ':::')
function Para(p)
    local txt = U.trim(pandoc.utils.stringify(p))
    if txt:match(":::%s*{%.plot%-function") or txt:match(":::%s*{%.plot%-file") or txt:match(":::%s*{%.dynamic%-plot") then
        error(string.format("[%s] Error: Malformed fenced block (ensure a blank line before ':::' and a space after ':::'): %s", TAG, txt))
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

    if has_plot_math then
        U.ensure_quarto_math(doc)
    end

    local payload = {}
    for _, def in ipairs(plot_defs) do
        local safe_json = pandoc.json.encode(def):gsub("</script>", "<\\/script>")
        table.insert(payload, string.format(
            '<script type="application/json" class="dynamic-plot-def" data-id="%s">%s</script>',
            U.html_escape(def.id),
            safe_json
        ))
    end
    table.insert(payload, U.load_template(PATHS.filter_rel, PATHS.template_rel, TAG, PANDOC_SCRIPT_FILE))

    U.inject_after_body(doc, table.concat(payload, "\n"))

    has_dynamic_plot = false
    has_plot_math = false
    plot_defs = {}
    return doc
end