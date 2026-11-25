-- =============================================================================
-- LaTeX to Quarto Pandoc Lua Filter
-- =============================================================================

-- Inline rules
local inline_rules = {

    -- Bold: \textbf{text}
    { pattern = "\\textbf{([^}]+)}", replace = function(t) return "**" .. t .. "**" end },

    -- Italic: \textit{text}
    { pattern = "\\textit{([^}]+)}", replace = function(t) return "*" .. t .. "*" end },

    -- Colored text: \textcolor{color}{text}
    { pattern = "\\textcolor{([^}]+)}{([^}]+)}", replace = function(c, t) return "[" .. t .. ']{style="color: ' .. c .. ';"}' end },
    
    -- Hyperlinks: \href{url}{text}
    { pattern = "\\href{([^}]+)}{([^}]+)}", replace = function(u, t) return "[" .. t .. "](" .. u .. ")" end },
    
    -- Citations: \cite{key1,key2} -> [@key1; @key2]
    { pattern = "\\cite{([^}]+)}", replace = function(cites)
        local refs = {}
        for ref in string.gmatch(cites, "[^,%s]+") do
            table.insert(refs, "@" .. ref)
        end
        return "[" .. table.concat(refs, "; ") .. "]"
    end },
    
    -- Generic references: \ref{fig:foo} -> [-@fig-foo]
    { pattern = "\\ref{([^}]+)}", replace = function(ref)
        ref = string.gsub(ref, ":", "-")
        return "[-@" .. ref .. "]"
    end },
    
    -- Equation references: \eqref{eq:foo} -> ([-@eq-foo])
    { pattern = "\\eqref{([^}]+)}", replace = function(ref)
        ref = string.gsub(ref, ":", "-")
        if not string.match(ref, "^eq%-") then ref = "eq-" .. ref end
        return "([-@" .. ref .. "])"
    end }

}

-- Math environment rules
local environment_rules = {
    equation = false, -- No inner environment needed.
    split = "split",
    align = "aligned",
    gather = "gathered"
}

-- Header hierarchy
local section_rules = {
    { cmd = "subsubsection", level = 3 },
    { cmd = "subsection",    level = 2 },
    { cmd = "section",       level = 1 }
}

local function transform_math(content, inner)
    local q_label
    content = content:gsub("\\label{([^}]+)}", function(label)
        if not q_label then
            q_label = label:gsub(":", "-")
            if not q_label:match("^eq%-") then
                q_label = "eq-" .. q_label
            end
        end
        return ""
    end)

    content = content:match("^%s*(.-)%s*$")
    if inner then
        content = "\\begin{" .. inner .. "}\n" .. content .. "\n\\end{" .. inner .. "}"
    end

    local md = "\n$$\n" .. content .. "\n$$"
    if q_label then
        md = md .. " {#" .. q_label .. "}"
    end
    return md .. "\n"
end

local function transform_prose(text)
    for _, sec in ipairs(section_rules) do
        local pattern = "\\" .. sec.cmd .. "{([^}]+)}"
        text = string.gsub(text, pattern, function(title)
            return "\n" .. string.rep("#", sec.level) .. " " .. title .. "\n"
        end)
    end

    for _, rule in ipairs(inline_rules) do
        text = string.gsub(text, rule.pattern, rule.replace)
    end

    return text
end

local function transform_tex(text)
    local parts = {}
    local prose_start = 1
    local search_start = 1

    -- Consume each complete math environment before looking for the next one.
    while true do
        local math_start, opening_end, env = text:find("\\begin{(%a+)%*?}", search_start)
        if not math_start then
            break
        end

        search_start = opening_end + 1
        local inner = environment_rules[env]
        if inner ~= nil then
            local closing_start, math_end = text:find("\\end{" .. env .. "%*?}", search_start)
            if closing_start then
                parts[#parts + 1] = transform_prose(text:sub(prose_start, math_start - 1))
                parts[#parts + 1] = transform_math(text:sub(search_start, closing_start - 1), inner)
                prose_start = math_end + 1
                search_start = prose_start
            end
        end
    end

    parts[#parts + 1] = transform_prose(text:sub(prose_start))
    return table.concat(parts)
end

-- Native Pandoc AST element entry points
function RawBlock(el)
    if el.format == "tex" or el.format == "latex" then
        local md = transform_tex(el.text)
        return pandoc.read(md, "markdown").blocks
    end
end

function RawInline(el)
    if el.format == "tex" or el.format == "latex" then
        local md = transform_tex(el.text)
        local doc = pandoc.read(md, "markdown")
        if doc.blocks[1] and doc.blocks[1].content then
            return doc.blocks[1].content
        end
        return {}
    end
end
