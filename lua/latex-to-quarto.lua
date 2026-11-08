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
    { env = "equation", inner = nil },
    { env = "split",    inner = "split" },
    { env = "align",    inner = "aligned" },
    { env = "gather",   inner = "gathered" }
}

-- Header hierarchy
local section_rules = {
    { cmd = "subsubsection", level = 3 },
    { cmd = "subsection",    level = 2 },
    { cmd = "section",       level = 1 }
}

-- Main transformation pipeline 
local function transform_tex(text)
    
    -- 1. Process LaTeX math environments into Quarto display math blocks
    for _, rule in ipairs(environment_rules) do
        local pattern = "\\begin{" .. rule.env .. "%*?}([%s%S]-)\\end{" .. rule.env .. "%*?}"
        text = string.gsub(text, pattern, function(content)
            local q_label = nil
            content = string.gsub(content, "\\label{([^}]+)}", function(lbl)
                if not q_label then
                    local formatted = string.gsub(lbl, ":", "-")
                    if not string.match(formatted, "^eq%-") then formatted = "eq-" .. formatted end
                    q_label = formatted
                end
                return ""
            end)
            
            content = content:match("^%s*(.-)%s*$")
            
            if rule.inner then
                content = "\\begin{" .. rule.inner .. "}\n" .. content .. "\n\\end{" .. rule.inner .. "}"
            end
            
            local md = "\n$$\n" .. content .. "\n$$"
            if q_label then
                md = md .. " {#" .. q_label .. "}"
            end
            return md .. "\n"
        end)
    end

    -- 2. Process LaTeX section headers
    for _, sec in ipairs(section_rules) do
        local pattern = "\\" .. sec.cmd .. "{([^}]+)}"
        text = string.gsub(text, pattern, function(title)
            return "\n" .. string.rep("#", sec.level) .. " " .. title .. "\n"
        end)
    end

    -- 3. Process inline formatting commands
    for _, rule in ipairs(inline_rules) do
        text = string.gsub(text, rule.pattern, rule.replace)
    end

    return text
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
