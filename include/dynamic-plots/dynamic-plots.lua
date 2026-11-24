-- =============================================================================
-- Dynamic Plots Lua Filter
-- =============================================================================

local TAG = "dynamic-plots.lua"
local SCRIPT_DIR = (PANDOC_SCRIPT_FILE and PANDOC_SCRIPT_FILE:match("(.*[/\\])")) or ""

local U
do
    local orig_path = package.path
    package.path = SCRIPT_DIR .. "../?.lua;" .. orig_path
    local ok, mod = pcall(require, "shared-utils")
    package.path = orig_path
    if not ok then
        error(string.format("[%s] Error: Required module 'shared-utils.lua' not found: %s", TAG, tostring(mod)))
    end
    U = mod
end

local DEFAULTS = {
    height         = 400,
    points_curve   = 100,
    points_surface = 40,
    steps          = 25,
    skip           = 0,
    xscale         = "linear",
    yscale         = "linear",
    zscale         = "linear",
    shade_opacity  = 0.2,
    play           = false,
    legend         = true
}

local MODES  = { lines = true, markers = true, ["lines+markers"] = true }
local SCALES = { linear = true, log = true }

local CONST_ENV = {
    pi    = math.pi,
    e     = math.exp(1),
    sin   = math.sin,
    cos   = math.cos,
    tan   = math.tan,
    asin  = math.asin,
    acos  = math.acos,
    atan  = function(x) return math.atan(x) end,
    atan2 = function(y, x) return math.atan(y, x) end,
    sinh  = function(x) return (math.exp(x) - math.exp(-x)) / 2 end,
    cosh  = function(x) return (math.exp(x) + math.exp(-x)) / 2 end,
    tanh  = function(x) local e2 = math.exp(2 * x); return (e2 - 1) / (e2 + 1) end,
    asinh = function(x) return math.log(x + math.sqrt(x * x + 1)) end,
    acosh = function(x) return math.log(x + math.sqrt(x * x - 1)) end,
    atanh = function(x) return 0.5 * math.log((1 + x) / (1 - x)) end,
    exp   = math.exp,
    log   = math.log,
    ln    = math.log,
    log10 = function(x) return math.log(x, 10) end,
    log2  = function(x) return math.log(x, 2) end,
    sqrt  = math.sqrt,
    abs   = math.abs,
    sign  = function(x) return x > 0 and 1 or (x < 0 and -1 or 0) end,
    floor = math.floor,
    ceil  = math.ceil,
    min   = math.min,
    max   = math.max,
    hypot = function(...)
        local s = 0
        for _, v in ipairs({ ... }) do s = s + v * v end
        return math.sqrt(s)
    end
}

local FUNCTION_RESERVED_KEYS = {
    x = true, y = true, z = true,
    vars = true, sliders = true, labels = true,
    steps = true, points = true,
    label = true, mode = true, smooth = true, color = true
}

local FILE_RESERVED_KEYS = {
    src = true, skip = true,
    x = true, y = true, z = true,
    vars = true, sliders = true, labels = true, steps = true,
    label = true, mode = true, smooth = true, color = true
}

local PLOT_KEYS = {
    curves = true, shade = true,
    xlabel = true, ylabel = true, zlabel = true,
    xscale = true, yscale = true, zscale = true,
    xrange = true, yrange = true, zrange = true,
    width = true, height = true,
    legend = true, play = true
}

local SHADE_OPTION_KEYS = {
    xrange = true, color = true, opacity = true, label = true
}

local has_dynamic_plot = false
local has_plot_math = false
local plot_defs = {}
local plot_configs = {}

-- Raises an immediate unwindable error that logs cleanly once in Quarto/Pandoc
local active_err = nil

local function fail(fmt, ...)
    active_err = string.format("[%s] Error: " .. fmt, TAG, ...)
    return (nil)()
end

local function run_safe(fallback, fn, ...)
    active_err = nil
    local ok, res = xpcall(fn, function(err)
        return active_err or debug.traceback(tostring(err), 2)
    end, ...)
    if not ok then
        local msg = active_err or res
        active_err = nil
        error(msg, 0)
        return fallback
    end
    return res
end

local function reset_state()
    has_dynamic_plot = false
    has_plot_math = false
    plot_defs = {}
    plot_configs = {}
end

local function track_math(str)
    if U.has_math(str) then
        has_plot_math = true
    end
end

local function is_valid_ident(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") ~= nil and CONST_ENV[name] == nil
end

local function strip_quotes(s)
    if type(s) ~= "string" then return s end
    return s:match('^"(.*)"$') or s:match("^'(.*)'$") or s
end

-- Evaluates a constant numeric expression in a sandboxed math environment
local function eval_const_expr(src, context)
    local trimmed = U.trim(src)
    if trimmed == "" or trimmed:find("[^0-9a-zA-Z_%.%+%-%*/%^%(%),%s]") then
        fail("Invalid constant expression '%s' in %s", src, context)
    end

    local sci_literals = {}
    local stash_sci = function(m)
        sci_literals[#sci_literals + 1] = "(" .. m .. ")"
        return "\1" .. #sci_literals .. "\2"
    end
    local protected = trimmed
        :gsub("(%d+%.?%d*[eE][+-]?%d+)", stash_sci)
        :gsub("(%.%d+[eE][+-]?%d+)", stash_sci)

    for ident in protected:gmatch("[a-zA-Z_][a-zA-Z0-9_]*") do
        if CONST_ENV[ident] == nil then
            fail("Identifier '%s' is not a constant in '%s' in %s", ident, src, context)
        end
    end

    local lua_expr = protected
        :gsub("%f[%w_](%d+%.?%d*)([a-zA-Z_(\1])", "%1*%2")
        :gsub("%f[%.%w_](%.%d+)([a-zA-Z_(\1])", "%1*%2")
        :gsub("([\2%)])([%d%a_(\1])", "%1*%2")
        :gsub("\1(%d+)\2", function(idx) return sci_literals[tonumber(idx)] end)

    local chunk = load("return (" .. lua_expr .. ")", "const", "t", CONST_ENV)
    local ok, val = false, nil
    if chunk then
        ok, val = pcall(chunk)
    end
    if not ok or type(val) ~= "number" or val ~= val or math.abs(val) == math.huge then
        fail("Failed to evaluate constant expression '%s' in %s", src, context)
    end
    return val
end

local function parse_bool(val, key, context)
    if val == nil then return nil end
    local lower = val:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end
    fail("Key '%s' in %s must be 'true' or 'false' (got '%s')", key, context, val)
end

local function parse_int(val, key, min_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or math.floor(n) ~= n or n < min_val then
        fail("Key '%s' in %s must be an integer >= %d (got '%s')", key, context, min_val, val)
    end
    return n
end

local function parse_float(val, key, min_val, max_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or n < min_val or n > max_val then
        fail("Key '%s' in %s must be a number in [%g, %g] (got '%s')", key, context, min_val, max_val, val)
    end
    return n
end

local function parse_enum(val, key, valid_map, context)
    if val == nil then return nil end
    if not valid_map[val] then
        fail("Invalid value '%s' for '%s' in %s", val, key, context)
    end
    return val
end

-- Splits top-level comma-separated items while respecting nested parentheses
local function split_top_commas(str)
    local items, depth, start = {}, 0, 1
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "(" then depth = depth + 1
        elseif ch == ")" then depth = depth - 1
        elseif ch == "," and depth == 0 then
            table.insert(items, U.trim(str:sub(start, i - 1)))
            start = i + 1
        end
    end
    table.insert(items, U.trim(str:sub(start)))
    return items
end

-- Parses a strict '[min, max]' numeric range
local function parse_range(val, key, context)
    if val == nil then return nil end
    local inner = val:match("^%[%s*(.-)%s*%]$")
    local parts = inner and split_top_commas(inner) or {}
    if #parts ~= 2 then
        fail("Key '%s' in %s must be '[min, max]' (got '%s')", key, context, val)
    end
    local lo, hi = eval_const_expr(parts[1], context), eval_const_expr(parts[2], context)
    if lo >= hi then
        fail("Key '%s' in %s must have min < max (got '%s')", key, context, val)
    end
    return { lo, hi }
end

-- Parses a parameter specification: '[min, max]', '[a..b]', or '[v1, v2, v3, ...]'
local function parse_param_spec(name, val, context)
    local inner = val:match("^%[%s*(.-)%s*%]$")
    if not inner or inner == "" then
        fail("Parameter '%s' in %s must be enclosed in '[...]' (got '%s')", name, context, val)
    end

    local s_tok, e_tok = inner:match("^(.-)%s*%.%.%s*(.-)$")
    if s_tok and e_tok then
        local lo, hi = eval_const_expr(s_tok, context), eval_const_expr(e_tok, context)
        if math.floor(lo) ~= lo or math.floor(hi) ~= hi or lo >= hi then
            fail("Integer step range '%s' for parameter '%s' in %s must have integer min < max", val, name, context)
        end
        local values = {}
        for v = lo, hi do table.insert(values, v) end
        return { name = name, kind = "list", values = values }
    end

    local parts = split_top_commas(inner)
    if #parts == 2 then
        local lo, hi = eval_const_expr(parts[1], context), eval_const_expr(parts[2], context)
        if lo >= hi then
            fail("Range '%s' for parameter '%s' in %s must have min < max", val, name, context)
        end
        return { name = name, kind = "range", min = lo, max = hi }
    elseif #parts >= 3 then
        local values = {}
        for _, item in ipairs(parts) do
            table.insert(values, eval_const_expr(item, context))
        end
        return { name = name, kind = "list", values = values }
    end
    fail("Parameter '%s' in %s must be '[min, max]', '[a..b]', or '[v1, v2, v3, ...]' (got '%s')", name, context, val)
end

-- Validates identifiers and dynamic column indexing 'c[...]' in an expression
local function validate_expr(expr, allowed_vars, allow_cols, context)
    local trimmed = U.trim(expr)
    if trimmed == "" then
        fail("Empty expression in %s", context)
    end
    if trimmed:find("=", 1, true) then
        fail("Expression '%s' in %s must not contain '='", expr, context)
    end
    if trimmed:find("[^0-9a-zA-Z_%.%+%-%*/%^%(%)%[%],%s]") then
        fail("Invalid character in expression '%s' in %s", expr, context)
    end

    local stripped, pos, len = {}, 1, #trimmed
    while pos <= len do
        local s_idx, e_idx = trimmed:find("%f[%w_]c%[", pos)
        if not s_idx then
            table.insert(stripped, trimmed:sub(pos))
            break
        end
        if not allow_cols then
            fail("Column indexing 'c[...]' is only allowed in '.plot-file' (%s)", context)
        end
        table.insert(stripped, trimmed:sub(pos, s_idx - 1))
        local depth, cur = 1, e_idx + 1
        while cur <= len and depth > 0 do
            local ch = trimmed:sub(cur, cur)
            if ch == "[" then depth = depth + 1 elseif ch == "]" then depth = depth - 1 end
            cur = cur + 1
        end
        if depth ~= 0 then
            fail("Unclosed 'c[...]' bracket in '%s' in %s", expr, context)
        end
        validate_expr(trimmed:sub(e_idx + 1, cur - 2), allowed_vars, allow_cols, context)
        table.insert(stripped, "0")
        pos = cur
    end

    local clean = table.concat(stripped)
    if clean:find("[", 1, true) or clean:find("]", 1, true) then
        fail("Unexpected '[' or ']' in expression '%s' in %s", expr, context)
    end

    local scrubbed = clean:gsub("%d+%.?%d*[eE][+-]?%d+", "0"):gsub("%.%d+[eE][+-]?%d+", "0")
    for ident in scrubbed:gmatch("[a-zA-Z_][a-zA-Z0-9_]*") do
        if CONST_ENV[ident] == nil and not allowed_vars[ident] then
            fail("Unknown or disallowed identifier '%s' in %s", ident, context)
        end
    end
end

-- Parses a curve definition block (.plot-function or .plot-file) with multi-line 'vars:' and 'labels:'
local function parse_curve_block(lines, reserved_keys, required_keys, context)
    local kv, vars, labels, param_order, param_specs = {}, {}, {}, {}, {}
    local section = nil

    for _, line in ipairs(lines) do
        local k_raw, v_raw = line:match("^([a-zA-Z_][%w_%-]*)%s*:%s*(.*)$")
        local k_lower = k_raw and k_raw:lower() or nil

        if section == "vars" and k_raw and (reserved_keys[k_lower] or is_valid_ident(k_raw)) then
            section = nil
        elseif section == "labels" and (not k_raw or reserved_keys[k_lower] or (not param_specs[k_raw] and U.trim(v_raw):match("^%[.*%]$"))) then
            section = nil
        end

        if section == "vars" then
            local vname, vexpr = line:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*=%s*(.+)$")
            if not vname or not is_valid_ident(vname) then
                fail("Invalid assignment inside 'vars:' in %s (expected 'name = expr'): %s", context, line)
            end
            table.insert(vars, { name = vname, expr = U.trim(vexpr) })
        elseif section == "labels" then
            local lval = U.trim(v_raw)
            if lval == "" then
                fail("Empty label for '%s' in 'labels:' of %s", k_raw, context)
            end
            if labels[k_raw] ~= nil then
                fail("Duplicate label for '%s' in 'labels:' of %s", k_raw, context)
            end
            labels[k_raw] = strip_quotes(lval)
        elseif k_raw then
            local val = U.trim(v_raw)
            if reserved_keys[k_lower] then
                if kv[k_lower] ~= nil then
                    fail("Duplicate key '%s' in %s", k_lower, context)
                end
                if k_lower == "vars" or k_lower == "labels" then
                    if val ~= "" then
                        fail("Key '%s' in %s must start a multi-line block (no inline value)", k_lower, context)
                    end
                    kv[k_lower] = true
                    section = k_lower
                else
                    if val == "" then
                        fail("Key '%s' in %s requires a value", k_lower, context)
                    end
                    kv[k_lower] = val
                end
            else
                if not is_valid_ident(k_raw) then
                    fail("Unknown or invalid key '%s' in %s", k_raw, context)
                end
                if param_specs[k_raw] ~= nil then
                    fail("Duplicate parameter '%s' in %s", k_raw, context)
                end
                table.insert(param_order, k_raw)
                param_specs[k_raw] = parse_param_spec(k_raw, val, context)
            end
        else
            fail("Invalid line in %s (expected 'key: value'): %s", context, line)
        end
    end

    for _, req in ipairs(required_keys) do
        if not kv[req] or kv[req] == "" then
            fail("Missing required key '%s' in %s", req, context)
        end
    end
    return kv, vars, labels, param_order, param_specs
end

-- Reads a comma-, tab-, or whitespace-delimited numeric matrix after stripping comments and skipped lines
local function read_numeric_matrix(src, skip, context)
    local file = U.open_data_file(src, SCRIPT_DIR)
    if not file then
        fail("Cannot open data file at '%s' in %s. Check file path.", src, context)
    end

    local rows, skipped, expected_cols, line_num = {}, 0, nil, 0
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
                        fail("Non-numeric value '%s' at line %d of '%s' in %s (use 'skip: N' to skip header rows)", clean, line_num, src, context)
                    end
                    table.insert(row, num)
                end
                if #row > 0 then
                    if expected_cols == nil then
                        expected_cols = #row
                    elseif #row ~= expected_cols then
                        file:close()
                        fail("Inconsistent column count at line %d of '%s' in %s (expected %d, got %d)", line_num, src, context, expected_cols, #row)
                    end
                    table.insert(rows, row)
                end
            end
        end
    end
    file:close()

    if #rows == 0 then
        fail("No numeric data rows found in '%s' for %s", src, context)
    end
    return rows
end

-- Finalizes parameter descriptors, slider assignments, and 'vars:' + coordinate expressions
local function finalize_curve_params_and_exprs(kv, vars, labels, param_order, param_specs, base_vars, allow_cols, context)
    local steps = parse_int(kv.steps, "steps", 2, context) or DEFAULTS.steps
    local slider_set = {}
    if kv.sliders then
        for tok in kv.sliders:gmatch("[^,]+") do
            local sname = U.trim(tok)
            if sname ~= "" then
                if not param_specs[sname] then
                    fail("Slider '%s' in %s does not match any declared parameter", sname, context)
                end
                if slider_set[sname] then
                    fail("Duplicate slider '%s' in %s", sname, context)
                end
                slider_set[sname] = true
            end
        end
        if not next(slider_set) then
            fail("Key 'sliders' in %s cannot be empty", context)
        end
    end

    for lname in pairs(labels) do
        if not slider_set[lname] then
            fail("Label '%s' in 'labels:' of %s must correspond to a parameter in 'sliders:'", lname, context)
        end
    end

    local params, domain_count = {}, 0
    for _, pname in ipairs(param_order) do
        local p = param_specs[pname]
        p.isSlider = slider_set[pname] == true
        if p.isSlider then
            if p.kind == "range" then p.steps = steps end
            p.label = labels[pname] or pname
            track_math(p.label)
        else
            domain_count = domain_count + 1
        end
        table.insert(params, p)
    end

    local allowed_vars = {}
    for k, v in pairs(base_vars) do allowed_vars[k] = v end
    for _, pname in ipairs(param_order) do allowed_vars[pname] = true end

    for _, v in ipairs(vars) do
        if param_specs[v.name] or base_vars[v.name] then
            fail("Variable '%s' in 'vars:' of %s cannot shadow a parameter or data column", v.name, context)
        end
        validate_expr(v.expr, allowed_vars, allow_cols, context)
        allowed_vars[v.name] = true
    end

    validate_expr(kv.x, allowed_vars, allow_cols, context)
    validate_expr(kv.y, allowed_vars, allow_cols, context)
    if kv.z then
        validate_expr(kv.z, allowed_vars, allow_cols, context)
    end

    return params, domain_count
end

-- Registers either a '.plot-function' or '.plot-file' block through a unified pipeline
local function register_curve_def(el, kind)
    local is_fn = (kind == "function")
    local tag_name = is_fn and ".plot-function" or ".plot-file"
    local id = U.trim(el.identifier)
    if id == "" then
        fail("'%s' block requires an 'id' attribute (e.g. ::: {%s id=\"c1\"})", tag_name, tag_name)
    end
    local context = tag_name .. "#" .. id
    local kv, vars, labels, param_order, param_specs = parse_curve_block(
        U.extract_lines_from_div(el),
        is_fn and FUNCTION_RESERVED_KEYS or FILE_RESERVED_KEYS,
        is_fn and {} or { "src", "x", "y" },
        context
    )

    local rows, base_vars = nil, {}
    if is_fn then
        for _, coord in ipairs({ "x", "y", "z" }) do
            local val = kv[coord]
            if val and val:match("^%[.*%]$") then
                table.insert(param_order, coord)
                param_specs[coord] = parse_param_spec(coord, val, context)
                kv[coord] = coord
            end
        end
        if not kv.x or not kv.y then
            fail("Both 'x' and 'y' must be defined (as parameters or coordinate expressions) in %s", context)
        end
    else
        local skip = parse_int(kv.skip, "skip", 0, context) or DEFAULTS.skip
        rows = read_numeric_matrix(strip_quotes(kv.src), skip, context)
        for i = 0, #rows[1] - 1 do base_vars["c" .. i] = true end
    end

    local params, domain_count = finalize_curve_params_and_exprs(
        kv, vars, labels, param_order, param_specs, base_vars, not is_fn, context
    )

    local dim = kv.z and "3d" or "2d"
    local subtype = "curve"
    local points = nil

    if is_fn then
        if domain_count < 1 or domain_count > 2 then
            fail("%s must have 1 domain parameter (curve) or 2 domain parameters (3D surface); got %d", context, domain_count)
        end
        if dim == "2d" and domain_count == 2 then
            fail("2D curve in %s cannot have 2 domain parameters (define 'z' for a 3D surface)", context)
        end
        subtype = (domain_count == 2) and "surface" or "curve"
        points = parse_int(kv.points, "points", 2, context)
            or (subtype == "surface" and DEFAULTS.points_surface or DEFAULTS.points_curve)
    elseif domain_count > 0 then
        fail("Every parameter declared in %s must be listed in 'sliders:'", context)
    end

    local label = strip_quotes(kv.label) or id
    track_math(label)

    table.insert(plot_defs, {
        kind    = kind,
        id      = id,
        dim     = dim,
        subtype = subtype,
        rows    = rows,
        params  = (#params > 0) and params or nil,
        vars    = (#vars > 0) and vars or nil,
        x       = kv.x,
        y       = kv.y,
        z       = kv.z,
        points  = points,
        label   = label,
        color   = strip_quotes(kv.color),
        mode    = parse_enum(kv.mode, "mode", MODES, context) or (is_fn and "lines" or "lines+markers"),
        smooth  = is_fn and (parse_bool(kv.smooth, "smooth", context) ~= false)
                        or (parse_bool(kv.smooth, "smooth", context) or false)
    })
    has_dynamic_plot = true
    return {}
end

-- Parses a shading rule header ('f1 -> f2' or 'f1 -> bottom:')
local function parse_shade_header(line, context)
    local lhs, rhs = line:match("^(.-)%s*%->%s*(.-)$")
    if not lhs then return nil end

    local has_opts = rhs:sub(-1) == ":"
    if has_opts then rhs = rhs:sub(1, -2) end
    lhs, rhs = U.trim(lhs), U.trim(rhs)

    if lhs == "" or rhs == "" then
        fail("Invalid shading rule '%s' in %s (expected 'curve -> target')", line, context)
    end

    local rule = { from = lhs, opacity = DEFAULTS.shade_opacity }
    if rhs == "bottom" or rhs == "top" then
        rule.toKind, rule.to = "bound", rhs
    elseif is_valid_ident(rhs) then
        rule.toKind, rule.to = "curve", rhs
    else
        rule.toKind, rule.to = "const", eval_const_expr(rhs, context)
    end
    return rule, has_opts
end

-- Parses a '.dynamic-plot' block including optional multi-line 'shade:' rules
local function parse_plot_block(lines, context)
    local kv, shade = {}, {}
    local in_shade, active_rule, active_has_opts, active_opt_count = false, nil, false, 0

    local function close_rule()
        if active_rule and active_has_opts and active_opt_count == 0 then
            fail("Shading rule '%s -> %s:' in %s has ':' but no options", active_rule.from, tostring(active_rule.to), context)
        end
        active_rule, active_has_opts, active_opt_count = nil, false, 0
    end

    for _, line in ipairs(lines) do
        local opt_k, opt_v = line:match("^([%w_%-]+)%s*:%s*(.*)$")
        local opt_lower = opt_k and opt_k:lower() or nil

        if in_shade and opt_lower and not (active_has_opts and SHADE_OPTION_KEYS[opt_lower]) and PLOT_KEYS[opt_lower] then
            close_rule()
            in_shade = false
        end

        if in_shade then
            if line:find("->", 1, true) then
                close_rule()
                local rule, has_opts = parse_shade_header(line, context)
                table.insert(shade, rule)
                active_rule, active_has_opts = rule, has_opts
            elseif active_has_opts and opt_lower and SHADE_OPTION_KEYS[opt_lower] then
                if active_rule[opt_lower] ~= nil then
                    fail("Duplicate shading option '%s' in %s", opt_lower, context)
                end
                active_opt_count = active_opt_count + 1
                local val = U.trim(opt_v)
                if opt_lower == "xrange" then
                    active_rule.xrange = parse_range(val, "xrange", context)
                elseif opt_lower == "color" then
                    active_rule.color = strip_quotes(val)
                elseif opt_lower == "opacity" then
                    active_rule.opacity = parse_float(val, "opacity", 0, 1, context)
                elseif opt_lower == "label" then
                    active_rule.label = strip_quotes(val)
                    track_math(active_rule.label)
                end
            else
                fail("Invalid line '%s' inside 'shade:' of %s", line, context)
            end
        elseif opt_lower then
            if not PLOT_KEYS[opt_lower] then
                fail("Unknown key '%s' in %s", opt_lower, context)
            end
            if kv[opt_lower] ~= nil then
                fail("Duplicate key '%s' in %s", opt_lower, context)
            end
            local val = U.trim(opt_v)
            if opt_lower == "shade" then
                if val ~= "" then
                    fail("Key 'shade' in %s must start a multi-line block (no inline value)", context)
                end
                kv.shade = true
                in_shade = true
            else
                if val == "" then
                    fail("Key '%s' in %s requires a value", opt_lower, context)
                end
                kv[opt_lower] = val
            end
        else
            fail("Invalid line in %s (expected 'key: value'): %s", context, line)
        end
    end

    close_rule()

    if kv.shade and #shade == 0 then
        fail("Key 'shade' in %s must contain at least one shading rule", context)
    end
    if not kv.curves or kv.curves == "" then
        fail("Missing required key 'curves' in %s", context)
    end
    return kv, shade
end

-- Builds the HTML mount container for a dynamic-plot canvas
local function render_plot_canvas(el)
    local id = U.trim(el.identifier)
    local context = (id ~= "") and (".dynamic-plot#" .. id) or ".dynamic-plot"
    local kv, shade = parse_plot_block(U.extract_lines_from_div(el), context)

    local curves = {}
    for item in kv.curves:gmatch("[^,]+") do
        local cid = U.trim(item)
        if cid ~= "" then table.insert(curves, cid) end
    end
    if #curves == 0 then
        fail("Key 'curves' in %s must list at least one curve ID", context)
    end

    local xlabel = strip_quotes(kv.xlabel)
    local ylabel = strip_quotes(kv.ylabel)
    local zlabel = strip_quotes(kv.zlabel)
    track_math(xlabel)
    track_math(ylabel)
    track_math(zlabel)

    local legend_opt = parse_bool(kv.legend, "legend", context)
    if legend_opt == nil then legend_opt = DEFAULTS.legend end

    local cfg = {
        curves = curves,
        shade  = (#shade > 0) and shade or nil,
        xlabel = xlabel,
        ylabel = ylabel,
        zlabel = zlabel,
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

-- Checks whether two slider parameter descriptors have identical ranges/values
local function sliders_compatible(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "range" then
        return a.min == b.min and a.max == b.max and a.steps == b.steps
    end
    if #a.values ~= #b.values then return false end
    for i = 1, #a.values do
        if a.values[i] ~= b.values[i] then return false end
    end
    return true
end

-- Validates curve references, dimensionality, shared sliders, shading targets, and log bounds
local function validate_plots()
    local defs_by_id = {}
    for _, def in ipairs(plot_defs) do
        if defs_by_id[def.id] then
            fail("Duplicate curve ID '%s'", def.id)
        end
        defs_by_id[def.id] = def
    end

    for _, item in ipairs(plot_configs) do
        local ctx, cfg = item.context, item.cfg
        local dim, curve_set, shared_sliders, slider_count = nil, {}, {}, 0

        for _, cid in ipairs(cfg.curves) do
            local def = defs_by_id[cid]
            if not def then
                fail("Unknown curve ID '%s' referenced in %s", cid, ctx)
            end
            curve_set[cid] = def
            if dim == nil then
                dim = def.dim
            elseif dim ~= def.dim then
                fail("Cannot mix 2D and 3D curves in %s", ctx)
            end

            for _, p in ipairs(def.params or {}) do
                if p.isSlider then
                    if not shared_sliders[p.name] then
                        shared_sliders[p.name] = p
                        slider_count = slider_count + 1
                    elseif not sliders_compatible(shared_sliders[p.name], p) then
                        fail("Conflicting definitions for shared slider '%s' in %s", p.name, ctx)
                    end
                end
            end
        end

        if cfg.play ~= nil and slider_count == 0 then
            fail("Key 'play' in %s requires at least one slider parameter", ctx)
        end
        if cfg.play == nil then
            cfg.play = DEFAULTS.play
        end

        if cfg.shade and #cfg.shade > 0 and dim ~= "2d" then
            fail("Key 'shade' is only supported in 2D plots (%s)", ctx)
        end

        for _, rule in ipairs(cfg.shade or {}) do
            if not curve_set[rule.from] then
                fail("Shading source '%s' must be listed in 'curves' of %s", rule.from, ctx)
            end
            if rule.toKind == "curve" then
                if not curve_set[rule.to] then
                    fail("Shading target '%s' must be listed in 'curves' of %s", rule.to, ctx)
                end
                if rule.from == rule.to and rule.xrange ~= nil then
                    fail("Closed-curve shading '%s -> %s' cannot specify 'xrange' in %s", rule.from, rule.to, ctx)
                end
            end
            if rule.xrange and cfg.xscale == "log" and rule.xrange[1] <= 0 then
                fail("Logarithmic xaxis requires positive shading 'xrange' bounds in %s", ctx)
            end
        end

        for _, axis in ipairs({ "x", "y", "z" }) do
            local r = cfg[axis .. "range"]
            if cfg[axis .. "scale"] == "log" and r and r[1] <= 0 then
                fail("Logarithmic %saxis requires positive bounds in %s", axis, ctx)
            end
        end
    end
end

-- Pandoc filter hook for '.plot-function', '.plot-file', and '.dynamic-plot' fenced divs
function Div(el)
    if el.classes:includes("plot-function") then
        return run_safe({}, register_curve_def, el, "function")
    elseif el.classes:includes("plot-file") then
        return run_safe({}, register_curve_def, el, "file")
    elseif el.classes:includes("dynamic-plot") then
        return run_safe({}, render_plot_canvas, el)
    end
    return nil
end

-- Pandoc document hook: validates definitions, injects serialized plot definitions and client assets
function Pandoc(doc)
    if not has_dynamic_plot then
        return doc
    end

    local ok = run_safe(false, function()
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
        return true
    end)

    reset_state()
    return ok and doc or doc
end