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

local has_plot_math = false
local plot_defs = {}
local plot_configs = {}

-- Terminates filter execution with a formatted error message
local function fail(fmt, ...)
    error(string.format("[%s] Error: " .. fmt, TAG, ...), 0)
end

-- Resets per-document filter state
local function reset_state()
    has_plot_math = false
    plot_defs = {}
    plot_configs = {}
end

-- Marks document math flag when LaTeX delimiters are detected
local function track_math(str)
    if U.has_math(str) then has_plot_math = true end
end

-- Validates math variable and parameter identifier names
local function is_valid_ident(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") ~= nil
end

-- Validates curve and plot identifier names (allowing hyphens)
local function is_valid_id(name)
    return type(name) == "string" and name:match("^[a-zA-Z_][%w_%-]*$") ~= nil
end

-- Parses a boolean option string
local function parse_bool(val, key, context)
    if val == nil then return nil end
    local lower = val:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end
    fail("Key '%s' in %s must be 'true' or 'false' (got '%s')", key, context, val)
end

-- Parses an integer option string with a lower bound
local function parse_int(val, key, min_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or math.floor(n) ~= n or n < min_val then
        fail("Key '%s' in %s must be an integer >= %d (got '%s')", key, context, min_val, val)
    end
    return n
end

-- Parses a floating-point option string within [min_val, max_val]
local function parse_float(val, key, min_val, max_val, context)
    if val == nil then return nil end
    local n = tonumber(val)
    if not n or n < min_val or n > max_val then
        fail("Key '%s' in %s must be a number in [%g, %g] (got '%s')", key, context, min_val, max_val, val)
    end
    return n
end

-- Parses an option string against an allowed lookup table
local function parse_enum(val, key, valid_map, context)
    if val == nil then return nil end
    if not valid_map[val] then
        fail("Invalid value '%s' for '%s' in %s", val, key, context)
    end
    return val
end

-- Separates the plot's range delimiters from the expressions evaluated in the browser.
local function range_body(val, context)
    local body = val:match("^%[%s*(.-)%s*%]$")
    if not body or body == "" then
        fail("Expected a nonempty range or list in %s (got '%s')", context, val)
    end
    return body
end

local function parse_range(val, key, context)
    return val and range_body(val, "'" .. key .. "' of " .. context)
end

local function parse_param_spec(name, val, context)
    local body = range_body(val, "parameter '" .. name .. "' of " .. context)
    local first, last = body:match("^(.-)%s*%.%.%s*(.-)$")
    if first then
        return { name = name, integerRange = {first, last} }
    end
    return { name = name, domain = body }
end

-- Parses an indented entry block ('sliders:' or 'shade:') with per-entry options
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

-- Parses key-value settings, variables, domain ranges, and sliders for a curve block
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
                -- Parse multi-line 'vars:' assignments
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
                -- Parse multi-line 'sliders:' entries and options
                if val ~= "" then fail("Key 'sliders' in %s must start a multi-line block", context) end
                kv.sliders = true
                slider_params, i = parse_entry_block(
                    lines, i + 1, "sliders", SLIDER_OPTIONS,
                    function(_, hk, hv)
                        if not hk or reserved_keys[hk:lower()] or SLIDER_OPTIONS[hk:lower()] then return nil end
                        if not is_valid_ident(hk) then fail("Invalid slider name '%s' in %s", hk, context) end
                        if seen_params[hk] then fail("Duplicate parameter '%s' in %s", hk, context) end
                        local p = parse_param_spec(hk, U.trim(hv):gsub(":%s*$", ""), context)
                        p.isSlider = true
                        p.play = DEFAULTS.play
                        seen_params[hk] = true
                        return p
                    end,
                    function(slider, opt, opt_val, ctx)
                        if opt == "steps" then
                            slider.steps = parse_int(opt_val, "steps", 2, ctx)
                        elseif opt == "label" then
                            if opt_val == "" then fail("Option 'label' for slider '%s' in %s cannot be empty", slider.name, ctx) end
                            slider.label = U.strip_quotes(opt_val)
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

-- Parses key-value settings and shading rules for a '.dynamic-plot' block
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
            -- Parse multi-line 'shade:' rules ('lower -> upper') and options
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
                        fail("Invalid shading rule '%s' in %s (expected 'lower -> upper')", line, context)
                    end
                    return {
                        from = lhs,
                        to = rhs,
                        opacity = DEFAULTS.shade_opacity
                    }
                end,
                function(rule, opt, opt_val, ctx)
                    if opt == "xrange" then rule.xrange = parse_range(opt_val, "xrange", ctx)
                    elseif opt == "color" then rule.color = U.strip_quotes(opt_val)
                    elseif opt == "opacity" then rule.opacity = parse_float(opt_val, "opacity", 0, 1, ctx)
                    elseif opt == "label" then
                        rule.label = U.strip_quotes(opt_val)
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

-- Loads a numeric matrix from a whitespace- or comma-separated data file
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
                local is_csv = trimmed:find(",", 1, true)
                local fields = is_csv and (trimmed .. ","):gmatch("(.-),") or trimmed:gmatch("%S+")
                local row = {}
                for tok in fields do
                    local clean = U.trim(tok)
                    local num = tonumber(clean)
                    if not num or math.abs(num) == math.huge then
                        file:close()
                        if clean == "" then
                            fail("Missing numeric value at line %d, column %d of '%s' in %s", line_num, #row + 1, src, context)
                        end
                        fail("Invalid numeric value '%s' at line %d, column %d of '%s' in %s (use 'skip: N' to skip header rows)",
                            clean, line_num, #row + 1, src, context)
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

-- Registers a '.plot-function' or '.plot-file' curve definition
local function register_curve_def(el, kind)
    local is_fn = (kind == "function")
    local tag_name = is_fn and ".plot-function" or ".plot-file"
    local id = U.trim(el.identifier)
    if not is_valid_id(id) then
        fail("'%s' block requires a valid ID (e.g. ~~~ {#c1 %s})", tag_name, tag_name)
    end
    local context = tag_name .. "#" .. id

    local kv, vars, domain_params, slider_params, seen_params = parse_curve_block(
        U.literal_lines(el.text),
        is_fn and FUNCTION_KEYS or FILE_KEYS,
        is_fn and {} or { "src", "x", "y" },
        is_fn,
        context
    )

    -- Promote bracketed coordinate ranges (e.g. 'x: [0, 10]') into domain parameters
    local rows
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
        rows = read_numeric_matrix(U.strip_quotes(kv.src), skip, context)
    end

    local params = {}
    for _, p in ipairs(domain_params) do table.insert(params, p) end
    for _, p in ipairs(slider_params) do
        p.label = p.label or p.name
        track_math(p.label)
        table.insert(params, p)
    end

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

    local label = U.strip_quotes(kv.label) or id
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
        color   = U.strip_quotes(kv.color),
        mode    = parse_enum(kv.mode, "mode", MODES, context) or (is_fn and "lines" or "lines+markers"),
        smooth  = is_fn and (parse_bool(kv.smooth, "smooth", context) ~= false)
                        or (parse_bool(kv.smooth, "smooth", context) or false)
    })
    return {}
end

-- Builds the HTML mount container for a '.dynamic-plot' block
local function render_plot_canvas(el)
    local id = U.trim(el.identifier)
    local context = (id ~= "") and (".dynamic-plot#" .. id) or ".dynamic-plot"
    local kv, shade = parse_plot_block(U.literal_lines(el.text), context)

    local curves = {}
    for item in kv.curves:gmatch("[^,]+") do
        local cid = U.trim(item)
        if cid ~= "" then table.insert(curves, cid) end
    end
    if #curves == 0 then fail("Key 'curves' in %s must list at least one curve ID", context) end

    local xlabel = U.strip_quotes(kv.xlabel)
    local ylabel = U.strip_quotes(kv.ylabel)
    local zlabel = U.strip_quotes(kv.zlabel)
    track_math(xlabel)
    track_math(ylabel)
    track_math(zlabel)

    local legend_opt = parse_bool(kv.legend, "legend", context)
    if legend_opt == nil then legend_opt = DEFAULTS.legend end

    local cfg = {
        curves = curves,
        context = context,
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
    table.insert(plot_configs, cfg)

    local id_attr = (id ~= "") and string.format(' id="%s"', U.html_escape(id)) or ""
    return pandoc.RawBlock("html", string.format('<div%s class="dynamic-plot-wrap" data-plot-idx="%d"></div>', id_attr, idx))
end

-- Checks structural relationships between curves and plots before publishing the page.
local function validate_plots()
    local defs_by_id = {}
    for _, def in ipairs(plot_defs) do
        if defs_by_id[def.id] then fail("Duplicate curve ID '%s'", def.id) end
        defs_by_id[def.id] = def
    end

    local function shade_kind(value)
        if value == "top" or value == "bottom" then return "bound" end
        return defs_by_id[value] and "curve" or "const"
    end

    for _, cfg in ipairs(plot_configs) do
        local ctx, dim, curve_set = cfg.context, nil, {}

        for _, cid in ipairs(cfg.curves) do
            local def = defs_by_id[cid]
            if not def then fail("Unknown curve ID '%s' referenced in %s", cid, ctx) end
            curve_set[cid] = def
            if dim == nil then dim = def.dim
            elseif dim ~= def.dim then fail("Cannot mix 2D and 3D curves in %s", ctx) end

        end

        if cfg.shade and dim ~= "2d" then
            fail("Key 'shade' is only supported in 2D plots (%s)", ctx)
        end

        for _, rule in ipairs(cfg.shade or {}) do
            rule.fromKind = shade_kind(rule.from)
            rule.toKind = shade_kind(rule.to)
            if rule.fromKind ~= "curve" and rule.toKind ~= "curve" then
                fail("Shading rule '%s -> %s' in %s must reference at least one curve ID", tostring(rule.from), tostring(rule.to), ctx)
            end
            if rule.fromKind == "bound" and rule.from == "top" then
                fail("Invalid shading direction 'top -> %s' in %s (use '%s -> top' to shade above)", tostring(rule.to), ctx, tostring(rule.to))
            end
            if rule.toKind == "bound" and rule.to == "bottom" then
                fail("Invalid shading direction '%s -> bottom' in %s (use 'bottom -> %s' to shade below)", tostring(rule.from), ctx, tostring(rule.from))
            end
            if rule.fromKind == "curve" and not curve_set[rule.from] then
                fail("Shading lower boundary '%s' must be listed in 'curves' of %s", rule.from, ctx)
            end
            if rule.toKind == "curve" and not curve_set[rule.to] then
                fail("Shading upper boundary '%s' must be listed in 'curves' of %s", rule.to, ctx)
            end
            if rule.fromKind == "curve" and rule.toKind == "curve" and rule.from == rule.to and rule.xrange ~= nil then
                fail("Closed-curve shading '%s -> %s' cannot specify 'xrange' in %s", rule.from, rule.to, ctx)
            end
        end
    end
end

-- Pandoc filter hook for literal plot configuration blocks.
function CodeBlock(el)
    if el.classes:includes("plot-function") then return register_curve_def(el, "function")
    elseif el.classes:includes("plot-file") then return register_curve_def(el, "file")
    elseif el.classes:includes("dynamic-plot") then return render_plot_canvas(el)
    end
    return nil
end

-- Pandoc document hook: validates plots, serializes definitions, and injects client assets
function Pandoc(doc)
    validate_plots()

    if #plot_configs > 0 then
        if has_plot_math then U.ensure_quarto_math(doc) end
        local payload = {
            defs = plot_defs,
            configs = plot_configs,
            sliderSteps = DEFAULTS.steps
        }
        local json = pandoc.json.encode(payload):gsub("<", "\\u003c")
        U.inject_after_body(doc, '<script type="application/json" class="dynamic-plot-data">' .. json .. '</script>')
        U.inject_widget(doc, "dynamic-plots", SCRIPT_DIR)
    end
    reset_state()
    return doc
end
