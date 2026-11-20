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
    height = 400,
    points = 100,
    skip   = 0,
    xscale = "linear",
    yscale = "linear",
    zscale = "linear",
    play   = false,
    legend = true
}

local MODES  = { lines = true, markers = true, ["lines+markers"] = true }
local SCALES = { linear = true, log = true }

local MATH_SYMBOLS = {
    pi = true, e = true,
    sin = true, cos = true, tan = true, asin = true, acos = true, atan = true,
    sinh = true, cosh = true, tanh = true, exp = true, log = true, ln = true,
    log10 = true, log2 = true, sqrt = true, abs = true, sign = true,
    floor = true, ceil = true, min = true, max = true
}

local FUNCTION_KEYS = {
    expr = true, label = true, xrange = true, yrange = true, zrange = true,
    points = true, mode = true, smooth = true, color = true
}

local FILE_KEYS = {
    src = true, skip = true, x = true, y = true, z = true,
    param = true, ["param-label"] = true, transform = true,
    label = true, mode = true, smooth = true, color = true
}

local PLOT_KEYS = {
    curves = true, xlabel = true, ylabel = true, zlabel = true,
    xscale = true, yscale = true, zscale = true,
    xrange = true, yrange = true, zrange = true,
    width = true, height = true,
    legend = true, play = true
}

local has_dynamic_plot = false
local has_plot_math = false
local plot_defs = {}
local plot_configs = {}

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

-- Validates identifiers and '=' usage in a mathematical expression and returns referenced variables
local function validate_expr(expr, allowed_vars, allow_equals, context)
    local _, eq_count = expr:gsub("=", "")
    if eq_count > 1 then
        error(string.format("[%s] Error: Expression '%s' in %s cannot contain multiple '=' signs", TAG, expr, context))
    end
    if eq_count == 1 and not allow_equals then
        error(string.format("[%s] Error: Explicit expression '%s' in %s must not contain '='", TAG, expr, context))
    end

    local scrubbed = expr:gsub("%d+%.?%d*[eE][+-]?%d+", "0"):gsub("%.%d+[eE][+-]?%d+", "0")
    local used_vars = {}
    for ident in scrubbed:gmatch("[a-zA-Z_][a-zA-Z0-9_]*") do
        if not MATH_SYMBOLS[ident] then
            if not allowed_vars[ident] then
                error(string.format("[%s] Error: Unknown or disallowed identifier '%s' in %s", TAG, ident, context))
            end
            used_vars[ident] = true
        end
    end
    return eq_count == 1, used_vars
end

-- Parses a column token 'cN' and verifies it falls within 0..num_cols-1
local function parse_col_index(token, num_cols, context)
    local idx_str = U.trim(token):match("^c(%d+)$")
    local idx = idx_str and tonumber(idx_str) or nil
    if not idx or idx < 0 or idx >= num_cols then
        error(string.format("[%s] Error: Invalid or out-of-range column '%s' in %s (expected c0..c%d)", TAG, U.trim(token), context, num_cols - 1))
    end
    return idx
end

-- Parses sweep columns ('c1..c5' or 'c1, c3, c5') into an array of 0-based indices
local function parse_sweep_cols(spec, num_cols, context)
    local start_tok, end_tok = U.trim(spec):match("^(c%d+)%s*%.%.%s*(c%d+)$")
    if start_tok then
        local s = parse_col_index(start_tok, num_cols, context)
        local e = parse_col_index(end_tok, num_cols, context)
        if s > e then
            error(string.format("[%s] Error: Column range '%s' in %s must be ascending", TAG, spec, context))
        end
        local cols = {}
        for c = s, e do table.insert(cols, c) end
        return cols
    end

    local cols = {}
    for tok in spec:gmatch("[^,]+") do
        table.insert(cols, parse_col_index(tok, num_cols, context))
    end
    if #cols == 0 then
        error(string.format("[%s] Error: 'y' sweep list cannot be empty in %s", TAG, context))
    end
    return cols
end

-- Formats a numeric sweep parameter cleanly for slider labels
local function format_param(val)
    local abs = math.abs(val)
    if abs > 0 and (abs < 1e-3 or abs >= 1e4) then
        return string.format("%.2e", val):gsub("e([+-])0+(%d)", "e%1%2")
    end
    local s = string.format("%.4f", val):gsub("%.?0+$", "")
    return s == "-0" and "0" or s
end

-- Parses sweep parameter values ('0..1' or '0.1, 0.5, 1.0') into formatted label strings
local function parse_sweep_params(spec, count, context)
    local s_str, e_str = U.trim(spec):match("^([+-]?%d*%.?%d+[eE]?[+-]?%d*)%s*%.%.%s*([+-]?%d*%.?%d+[eE]?[+-]?%d*)$")
    if s_str and tonumber(s_str) and tonumber(e_str) then
        if count < 2 then
            error(string.format("[%s] Error: 'param' range '%s' in %s requires at least 2 sweep columns", TAG, spec, context))
        end
        local start_v, end_v = tonumber(s_str), tonumber(e_str)
        local step = (end_v - start_v) / (count - 1)
        local labels = {}
        for i = 0, count - 1 do
            table.insert(labels, format_param(start_v + i * step))
        end
        return labels
    end

    local labels = {}
    for tok in spec:gmatch("[^,]+") do
        local num = tonumber(U.trim(tok))
        if not num then
            error(string.format("[%s] Error: Non-numeric parameter value '%s' in %s", TAG, U.trim(tok), context))
        end
        table.insert(labels, format_param(num))
    end
    if #labels ~= count then
        error(string.format("[%s] Error: 'param' has %d values, but 'y' selects %d columns in %s", TAG, #labels, count, context))
    end
    return labels
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
    local has_eq, vars = validate_expr(kv.expr, { x = true, y = true, z = true }, true, context)

    if not has_eq and vars.z then
        error(string.format("[%s] Error: Explicit expression '%s' in %s cannot contain 'z' (use '=' for implicit 3D surfaces)", TAG, kv.expr, context))
    end

    local dim, subtype
    if has_eq then
        dim = vars.z and "3d" or "2d"
        subtype = vars.z and "3d-implicit" or "2d-implicit"
    else
        dim = vars.y and "3d" or "2d"
        subtype = vars.y and "3d-explicit" or "2d-explicit"
    end

    local label = kv.label or id
    track_math(label)

    table.insert(plot_defs, {
        kind    = "function",
        id      = id,
        dim     = dim,
        subtype = subtype,
        isSweep = false,
        expr    = kv.expr,
        label   = label,
        color   = kv.color,
        xrange  = parse_range(kv.xrange, "xrange", context),
        yrange  = parse_range(kv.yrange, "yrange", context),
        zrange  = parse_range(kv.zrange, "zrange", context),
        points  = parse_int(kv.points, "points", 2, context),
        mode    = has_eq and "lines" or (parse_enum(kv.mode, "mode", MODES, context) or "lines"),
        smooth  = parse_bool(kv.smooth, "smooth", context)
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

    local is_sweep = kv.param ~= nil
    if is_sweep then
        if kv.z ~= nil then
            error(string.format("[%s] Error: Key 'z' is not allowed in parameter-sweep mode in %s", TAG, context))
        end
    else
        for _, sweep_only in ipairs({ "transform", "param-label" }) do
            if kv[sweep_only] ~= nil then
                error(string.format("[%s] Error: Key '%s' requires 'param' in %s", TAG, sweep_only, context))
            end
        end
    end

    local skip = parse_int(kv.skip, "skip", 0, context) or DEFAULTS.skip
    local rows = read_numeric_matrix(kv.src, skip, context)
    local num_cols = #rows[1]
    local col_vars = {}
    for i = 0, num_cols - 1 do col_vars["c" .. i] = true end

    validate_expr(kv.x, col_vars, false, context)

    local sweep_cols, params
    if is_sweep then
        sweep_cols = parse_sweep_cols(kv.y, num_cols, context)
        params = parse_sweep_params(kv.param, #sweep_cols, context)
        if kv.transform then
            local t_vars = { y = true }
            for k, v in pairs(col_vars) do t_vars[k] = v end
            validate_expr(kv.transform, t_vars, false, context)
        end
    else
        validate_expr(kv.y, col_vars, false, context)
        if kv.z then
            validate_expr(kv.z, col_vars, false, context)
        end
    end

    local label = kv.label or id
    local param_label = kv["param-label"] or "Parameter"
    track_math(label)
    track_math(param_label)

    table.insert(plot_defs, {
        kind       = "file",
        id         = id,
        dim        = (not is_sweep and kv.z) and "3d" or "2d",
        isSweep    = is_sweep,
        rows       = rows,
        x          = kv.x,
        y          = kv.y,
        z          = kv.z,
        sweepCols  = sweep_cols,
        params     = params,
        paramLabel = param_label,
        transform  = kv.transform,
        label      = label,
        color      = kv.color,
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

    local legend_opt = parse_bool(kv.legend, "legend", context)
    if legend_opt == nil then legend_opt = DEFAULTS.legend end

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
        width  = parse_int(kv.width, "width", 200, context),
        height = parse_int(kv.height, "height", 200, context) or DEFAULTS.height,
        legend = legend_opt,
        play   = parse_bool(kv.play, "play", context)
    }

    table.insert(plot_configs, { context = context, cfg = cfg })
    has_dynamic_plot = true

    local id_attr = (id ~= "") and string.format(' id="%s"', U.html_escape(id)) or ""
    local html = string.format(
        '<div%s class="dynamic-plot-wrap" data-plot-config="%s"></div>',
        id_attr,
        U.html_escape(pandoc.json.encode(cfg))
    )
    return pandoc.RawBlock("html", html)
end

-- Validates curve references, dimensionality, sweep uniqueness, and log bounds across all plots
local function validate_plots()
    local defs_by_id = {}
    for _, def in ipairs(plot_defs) do
        if defs_by_id[def.id] then
            error(string.format("[%s] Error: Duplicate curve ID '%s'", TAG, def.id))
        end
        defs_by_id[def.id] = def
    end

    for _, item in ipairs(plot_configs) do
        local ctx, cfg = item.context, item.cfg
        local dim, sweep_count = nil, 0

        for _, cid in ipairs(cfg.curves) do
            local def = defs_by_id[cid]
            if not def then
                error(string.format("[%s] Error: Unknown curve ID '%s' referenced in %s", TAG, cid, ctx))
            end
            if dim == nil then
                dim = def.dim
            elseif dim ~= def.dim then
                error(string.format("[%s] Error: Cannot mix 2D and 3D curves in %s", TAG, ctx))
            end
            if def.isSweep then
                sweep_count = sweep_count + 1
            end
        end

        if sweep_count > 1 then
            error(string.format("[%s] Error: Cannot combine multiple parameter-sweep curves in %s", TAG, ctx))
        end
        if cfg.play ~= nil and sweep_count == 0 then
            error(string.format("[%s] Error: Key 'play' in %s requires a parameter-sweep curve", TAG, ctx))
        end
        if cfg.play == nil then
            cfg.play = DEFAULTS.play
        end

        for _, axis in ipairs({ "x", "y", "z" }) do
            local r = cfg[axis .. "range"]
            if cfg[axis .. "scale"] == "log" and r and r[1] <= 0 then
                error(string.format("[%s] Error: Logarithmic %saxis requires positive bounds in %s", TAG, axis, ctx))
            end
        end
    end
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

-- Pandoc document hook: validates definitions, injects serialized plot definitions and client assets
function Pandoc(doc)
    if not has_dynamic_plot then
        return doc
    end

    validate_plots()

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

    U.inject_after_body(doc, table.concat(payload, "\n"))
    U.inject_widget(doc, "dynamic-plots", SCRIPT_DIR)

    has_dynamic_plot = false
    has_plot_math = false
    plot_defs = {}
    plot_configs = {}
    return doc
end