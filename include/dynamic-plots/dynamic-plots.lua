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
        error(string.format("[%s] Error: Required module 'shared-utils.lua' not found: %s", TAG, tostring(mod)), 0)
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

local FUNCTION_KEYS = {
    x = true, y = true, z = true, vars = true, sliders = true,
    points = true, label = true, mode = true, smooth = true, color = true
}

local FILE_KEYS = {
    src = true, skip = true, x = true, y = true, z = true, vars = true, sliders = true,
    label = true, mode = true, smooth = true, color = true
}

local SLIDER_OPTIONS = { steps = true, label = true, play = true }
local SHADE_OPTIONS  = { xrange = true, color = true, opacity = true, label = true }

local PLOT_KEYS = {
    curves = true, shade = true,
    xlabel = true, ylabel = true, zlabel = true,
    xscale = true, yscale = true, zscale = true,
    xrange = true, yrange = true, zrange = true,
    width = true, height = true, legend = true
}

local has_dynamic_plot = false
local has_plot_math = false
local plot_defs = {}
local plot_configs = {}

local function fail(fmt, ...)
    error(string.format("[%s] Error: " .. fmt, TAG, ...), 0)
end

local function reset_state()
    has_dynamic_plot = false
    has_plot_math = false
    plot_defs = {}
    plot_configs = {}
end

local function track_math(str)
    if U.has_math(str) then has_plot_math = true end
end

local function is_valid_ident(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") ~= nil and CONST_ENV[name] == nil
end

local function is_valid_id(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][%w_%-]*$") ~= nil and CONST_ENV[name] == nil
end

local function is_valid_ident(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") ~= nil and CONST_ENV[name] == nil
end

local function strip_quotes(s)
    if type(s) ~= "string" then return s end
    return s:match('^"(.*)"$') or s:match("^'(.*)'$") or s
end

-- Visits every non-scientific-notation identifier in an expression
local function each_identifier(expr, fn)
    local scrubbed = expr:gsub("%d+%.?%d*[eE][+-]?%d+", "0"):gsub("%.%d+[eE][+-]?%d+", "0")
    for ident in scrubbed:gmatch("[a-zA-Z_][a-zA-Z0-9_]*") do
        fn(ident)
    end
end

-- Evaluates a constant numeric expression in a sandboxed math environment
local function eval_const_expr(src, context)
    local trimmed = U.trim(src)
    if trimmed == "" or trimmed:find("[^0-9a-zA-Z_%.%+%-%*/%^%(%),%s]") then
        fail("Invalid constant expression '%s' in %s", src, context)
    end

    each_identifier(trimmed, function(ident)
        if CONST_ENV[ident] == nil then
            fail("Identifier '%s' is not a constant in '%s' in %s", ident, src, context)
        end
    end)

    local sci_literals = {}
    local protected = trimmed
        :gsub("(%d+%.?%d*[eE][+-]?%d+)", function(m) sci_literals[#sci_literals + 1] = "(" .. m .. ")"; return "\1" .. #sci_literals .. "\2" end)
        :gsub("(%.%d+[eE][+-]?%d+)", function(m) sci_literals[#sci_literals + 1] = "(" .. m .. ")"; return "\1" .. #sci_literals .. "\2" end)

    local lua_expr = protected
        :gsub("%f[%w_](%d+%.?%d*)([a-zA-Z_(\1])", "%1*%2")
        :gsub("%f[%.%w_](%.%d+)([a-zA-Z_(\1])", "%1*%2")
        :gsub("([\2%)])([%d%a_(\1])", "%1*%2")
        :gsub("\1(%d+)\2", function(idx) return sci_literals[tonumber(idx)] end)

    local chunk = load("return (" .. lua_expr .. ")", "const", "t", CONST_ENV)
    local ok, val = false, nil
    if chunk then ok, val = pcall(chunk) end
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

local function validate_expr(expr, allowed_vars, allow_cols, context)
    local trimmed = U.trim(expr)
    if trimmed == "" then fail("Empty expression in %s", context) end
    if trimmed:find("=", 1, true) then fail("Expression '%s' in %s must not contain '='", expr, context) end
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
        if depth ~= 0 then fail("Unclosed 'c[...]' bracket in '%s' in %s", expr, context) end
        validate_expr(trimmed:sub(e_idx + 1, cur - 2), allowed_vars, allow_cols, context)
        table.insert(stripped, "0")
        pos = cur
    end

    local clean = table.concat(stripped)
    if clean:find("[", 1, true) or clean:find("]", 1, true) then
        fail("Unexpected '[' or ']' in expression '%s' in %s", expr, context)
    end

    each_identifier(clean, function(ident)
        if CONST_ENV[ident] == nil and not allowed_vars[ident] then
            fail("Unknown or disallowed identifier '%s' in %s", ident, context)
        end
    end)
end

-- Generic sub-block parser for 'sliders:' and 'shade:' (entries with optional indented 'key: value' options)
local function parse_entry_block(lines, start_idx, block_name, option_keys, parse_header, apply_option, context)
    local entries, current, seen_opts = {}, nil, nil
    local i = start_idx

    while i <= #lines do
        local line = lines[i]
        local k_raw, v_raw = line:match("^([a-zA-Z_][%w_%-]*)%s*:%s*(.*)$")
        local k_lower = k_raw and k_raw:lower() or nil

        if current and k_lower and option_keys[k_lower] then
            if seen_opts[k_lower] then
                fail("Duplicate option '%s' inside '%s:' of %s", k_lower, block_name, context)
            end
            seen_opts[k_lower] = true
            apply_option(current, k_lower, U.trim(v_raw), context)
            i = i + 1
        else
            local entry = parse_header(line, k_raw, v_raw)
            if not entry then break end
            current = entry
            seen_opts = {}
            table.insert(entries, entry)
            i = i + 1
        end
    end

    if #entries == 0 then
        fail("Block '%s:' in %s must contain at least one entry", block_name, context)
    end
    return entries, i
end

-- Parses a '.plot-function' or '.plot-file' block
local function parse_curve_block(lines, reserved_keys, required_keys, allow_domain_params, context)
    local kv, vars, domain_params, slider_params, seen_params = {}, {}, {}, {}, {}
    local i = 1

    while i <= #lines do
        local k_raw, v_raw = lines[i]:match("^([a-zA-Z_][%w_%-]*)%s*:%s*(.*)$")
        local k_lower = k_raw and k_raw:lower() or nil
        if not k_raw then
            fail("Invalid line in %s (expected 'key: value'): %s", context, lines[i])
        end
        local val = U.trim(v_raw)

        if reserved_keys[k_lower] then
            if kv[k_lower] ~= nil then fail("Duplicate key '%s' in %s", k_lower, context) end
            if k_lower == "vars" then
                if val ~= "" then fail("Key 'vars' in %s must start a multi-line block", context) end
                kv.vars = true
                i = i + 1
                while i <= #lines do
                    local vname, vexpr = lines[i]:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*=%s*(.+)$")
                    if not vname then break end
                    if not is_valid_ident(vname) then fail("Invalid variable name '%s' in 'vars:' of %s", vname, context) end
                    table.insert(vars, { name = vname, expr = U.trim(vexpr) })
                    i = i + 1
                end
            elseif k_lower == "sliders" then
                if val ~= "" then fail("Key 'sliders' in %s must start a multi-line block", context) end
                kv.sliders = true
                slider_params, i = parse_entry_block(
                    lines, i + 1, "sliders", SLIDER_OPTIONS,
                    function(_, hk, hv)
                        if not hk or reserved_keys[hk:lower()] or SLIDER_OPTIONS[hk:lower()] then return nil end
                        if not is_valid_ident(hk) then fail("Invalid slider name '%s' in %s", hk, context) end
                        if seen_params[hk] then fail("Duplicate parameter '%s' in %s", hk, context) end
                        local spec_str = U.trim(hv):gsub(":%s*$", "")
                        local p = parse_param_spec(hk, spec_str, context)
                        p.isSlider = true
                        p.play = DEFAULTS.play
                        seen_params[hk] = true
                        return p
                    end,
                    function(slider, opt, opt_val, ctx)
                        if opt == "steps" then
                            if slider.kind ~= "range" then
                                fail("Option 'steps' for slider '%s' in %s is only valid for '[min, max]' ranges", slider.name, ctx)
                            end
                            slider.steps = parse_int(opt_val, "steps", 2, ctx)
                        elseif opt == "label" then
                            if opt_val == "" then fail("Option 'label' for slider '%s' in %s cannot be empty", slider.name, ctx) end
                            slider.label = strip_quotes(opt_val)
                        elseif opt == "play" then
                            slider.play = parse_bool(opt_val, "play", ctx)
                        end
                    end,
                    context
                )
            else
                if val == "" then fail("Key '%s' in %s requires a value", k_lower, context) end
                kv[k_lower] = val
                i = i + 1
            end
        else
            if not allow_domain_params then
                fail("Unknown key '%s' in %s (declare interactive sliders inside 'sliders:')", k_raw, context)
            end
            if not is_valid_ident(k_raw) then fail("Unknown or invalid key '%s' in %s", k_raw, context) end
            if seen_params[k_raw] then fail("Duplicate parameter '%s' in %s", k_raw, context) end
            local p = parse_param_spec(k_raw, val, context)
            p.isSlider = false
            seen_params[k_raw] = true
            table.insert(domain_params, p)
            i = i + 1
        end
    end

    for _, req in ipairs(required_keys) do
        if not kv[req] or kv[req] == "" then fail("Missing required key '%s' in %s", req, context) end
    end
    return kv, vars, domain_params, slider_params, seen_params
end

local function read_numeric_matrix(src, skip, context)
    local file = U.open_data_file(src, SCRIPT_DIR)
    if not file then fail("Cannot open data file at '%s' in %s. Check file path.", src, context) end

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
                    if expected_cols == nil then expected_cols = #row
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

    if #rows == 0 then fail("No numeric data rows found in '%s' for %s", src, context) end
    return rows
end

local function register_curve_def(el, kind)
    local is_fn = (kind == "function")
    local tag_name = is_fn and ".plot-function" or ".plot-file"
    local id = U.trim(el.identifier)
    if id == "" then fail("'%s' block requires an 'id' attribute (e.g. ::: {%s id=\"c1\"})", tag_name, tag_name) end
    local context = tag_name .. "#" .. id

    local kv, vars, domain_params, slider_params, seen_params = parse_curve_block(
        U.extract_lines_from_div(el),
        is_fn and FUNCTION_KEYS or FILE_KEYS,
        is_fn and {} or { "src", "x", "y" },
        is_fn,
        context
    )

    local rows, base_vars = nil, {}
    if is_fn then
        for _, coord in ipairs({ "x", "y", "z" }) do
            local val = kv[coord]
            if val and val:match("^%[.*%]$") then
                if seen_params[coord] then fail("Duplicate domain parameter '%s' in %s", coord, context) end
                local p = parse_param_spec(coord, val, context)
                p.isSlider = false
                seen_params[coord] = true
                table.insert(domain_params, p)
                kv[coord] = coord
            end
        end
        if not kv.x or not kv.y then
            fail("Both 'x' and 'y' must be defined (as domain ranges or coordinate expressions) in %s", context)
        end
    else
        local skip = parse_int(kv.skip, "skip", 0, context) or DEFAULTS.skip
        rows = read_numeric_matrix(strip_quotes(kv.src), skip, context)
        for i = 0, #rows[1] - 1 do base_vars["c" .. i] = true end
    end

    local params = {}
    for _, p in ipairs(domain_params) do table.insert(params, p) end
    for _, p in ipairs(slider_params) do
        if p.kind == "range" and p.steps == nil then p.steps = DEFAULTS.steps end
        p.label = p.label or p.name
        track_math(p.label)
        table.insert(params, p)
    end

    local allowed_vars = {}
    for k, v in pairs(base_vars) do allowed_vars[k] = v end
    for pname in pairs(seen_params) do allowed_vars[pname] = true end

    for _, v in ipairs(vars) do
        if seen_params[v.name] or base_vars[v.name] then
            fail("Variable '%s' in 'vars:' of %s cannot shadow a parameter or data column", v.name, context)
        end
        validate_expr(v.expr, allowed_vars, not is_fn, context)
        allowed_vars[v.name] = true
    end

    validate_expr(kv.x, allowed_vars, not is_fn, context)
    validate_expr(kv.y, allowed_vars, not is_fn, context)
    if kv.z then validate_expr(kv.z, allowed_vars, not is_fn, context) end

    local dim = kv.z and "3d" or "2d"
    local subtype, points = "curve", nil
    if is_fn then
        if #domain_params < 1 or #domain_params > 2 then
            fail("%s must have 1 domain parameter (curve) or 2 domain parameters (3D surface); got %d", context, #domain_params)
        end
        if dim == "2d" and #domain_params == 2 then
            fail("2D curve in %s cannot have 2 domain parameters (define 'z' for a 3D surface)", context)
        end
        subtype = (#domain_params == 2) and "surface" or "curve"
        points = parse_int(kv.points, "points", 2, context)
            or (subtype == "surface" and DEFAULTS.points_surface or DEFAULTS.points_curve)
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

local function parse_plot_block(lines, context)
    local kv, shade, i = {}, {}, 1

    while i <= #lines do
        local opt_k, opt_v = lines[i]:match("^([%w_%-]+)%s*:%s*(.*)$")
        local opt_lower = opt_k and opt_k:lower() or nil
        if not opt_lower or not PLOT_KEYS[opt_lower] then
            fail("Invalid or unknown key in %s: %s", context, lines[i])
        end
        if kv[opt_lower] ~= nil then fail("Duplicate key '%s' in %s", opt_lower, context) end
        local val = U.trim(opt_v)

        if opt_lower == "shade" then
            if val ~= "" then fail("Key 'shade' in %s must start a multi-line block", context) end
            kv.shade = true
            shade, i = parse_entry_block(
                lines, i + 1, "shade", SHADE_OPTIONS,
                function(line)
                    local lhs, rhs = line:match("^(.-)%s*%->%s*(.-)$")
                    if not lhs then return nil end
                    lhs = U.trim(lhs)
                    rhs = U.trim(rhs):gsub(":%s*$", "")
                    if lhs == "" or rhs == "" then
                        fail("Invalid shading rule '%s' in %s (expected 'curve -> target')", line, context)
                    end
                    local rule = { from = lhs, opacity = DEFAULTS.shade_opacity }
                    if rhs == "bottom" or rhs == "top" then
                        rule.toKind, rule.to = "bound", rhs
                    elseif is_valid_id(rhs) then
                        rule.toKind, rule.to = "curve", rhs
                    else
                        rule.toKind, rule.to = "const", eval_const_expr(rhs, context)
                    end
                    return rule
                end,
                function(rule, opt, opt_val, ctx)
                    if opt == "xrange" then rule.xrange = parse_range(opt_val, "xrange", ctx)
                    elseif opt == "color" then rule.color = strip_quotes(opt_val)
                    elseif opt == "opacity" then rule.opacity = parse_float(opt_val, "opacity", 0, 1, ctx)
                    elseif opt == "label" then
                        rule.label = strip_quotes(opt_val)
                        track_math(rule.label)
                    end
                end,
                context
            )
        else
            if val == "" then fail("Key '%s' in %s requires a value", opt_lower, context) end
            kv[opt_lower] = val
            i = i + 1
        end
    end

    if not kv.curves or kv.curves == "" then fail("Missing required key 'curves' in %s", context) end
    return kv, shade
end

local function render_plot_canvas(el)
    local id = U.trim(el.identifier)
    local context = (id ~= "") and (".dynamic-plot#" .. id) or ".dynamic-plot"
    local kv, shade = parse_plot_block(U.extract_lines_from_div(el), context)

    local curves = {}
    for item in kv.curves:gmatch("[^,]+") do
        local cid = U.trim(item)
        if cid ~= "" then table.insert(curves, cid) end
    end
    if #curves == 0 then fail("Key 'curves' in %s must list at least one curve ID", context) end

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
        legend = legend_opt
    }

    local idx = #plot_configs + 1
    table.insert(plot_configs, { idx = idx, context = context, cfg = cfg })
    has_dynamic_plot = true

    local id_attr = (id ~= "") and string.format(' id="%s"', U.html_escape(id)) or ""
    return pandoc.RawBlock("html", string.format('<div%s class="dynamic-plot-wrap" data-plot-idx="%d"></div>', id_attr, idx))
end

local function sliders_compatible(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "range" then return a.min == b.min and a.max == b.max and a.steps == b.steps end
    if #a.values ~= #b.values then return false end
    for i = 1, #a.values do
        if a.values[i] ~= b.values[i] then return false end
    end
    return true
end

local function validate_plots()
    local defs_by_id = {}
    for _, def in ipairs(plot_defs) do
        if defs_by_id[def.id] then fail("Duplicate curve ID '%s'", def.id) end
        defs_by_id[def.id] = def
    end

    for _, item in ipairs(plot_configs) do
        local ctx, cfg = item.context, item.cfg
        local dim, curve_set, shared_sliders = nil, {}, {}

        for _, cid in ipairs(cfg.curves) do
            local def = defs_by_id[cid]
            if not def then fail("Unknown curve ID '%s' referenced in %s", cid, ctx) end
            curve_set[cid] = def
            if dim == nil then dim = def.dim
            elseif dim ~= def.dim then fail("Cannot mix 2D and 3D curves in %s", ctx) end

            for _, p in ipairs(def.params or {}) do
                if p.isSlider then
                    if not shared_sliders[p.name] then shared_sliders[p.name] = p
                    elseif not sliders_compatible(shared_sliders[p.name], p) then
                        fail("Conflicting definitions for shared slider '%s' in %s", p.name, ctx)
                    end
                end
            end
        end

        if cfg.shade and dim ~= "2d" then
            fail("Key 'shade' is only supported in 2D plots (%s)", ctx)
        end

        for _, rule in ipairs(cfg.shade or {}) do
            if not curve_set[rule.from] then fail("Shading source '%s' must be listed in 'curves' of %s", rule.from, ctx) end
            if rule.toKind == "curve" then
                if not curve_set[rule.to] then fail("Shading target '%s' must be listed in 'curves' of %s", rule.to, ctx) end
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

function Div(el)
    if el.classes:includes("plot-function") then return register_curve_def(el, "function")
    elseif el.classes:includes("plot-file") then return register_curve_def(el, "file")
    elseif el.classes:includes("dynamic-plot") then return render_plot_canvas(el)
    end
    return nil
end

function Pandoc(doc)
    if not has_dynamic_plot then return doc end

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
    for _, item in ipairs(plot_configs) do
        local safe_json = pandoc.json.encode(item.cfg):gsub("</script>", "<\\/script>")
        table.insert(payload, string.format(
            '<script type="application/json" class="dynamic-plot-cfg" data-idx="%d">%s</script>',
            item.idx,
            safe_json
        ))
    end

    U.inject_after_body(doc, table.concat(payload, "\n"))
    U.inject_widget(doc, "dynamic-plots", SCRIPT_DIR)
    reset_state()
    return doc
end