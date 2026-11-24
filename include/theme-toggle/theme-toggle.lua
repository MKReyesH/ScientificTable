-- =============================================================================
-- Theme Toggle Lua Filter
-- =============================================================================

local TAG = "theme-toggle.lua"
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

function Pandoc(doc)
    U.inject_widget(doc, "theme-toggle", SCRIPT_DIR)
    return doc
end