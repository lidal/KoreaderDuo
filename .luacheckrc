-- Lint configuration, matching KOReader's own so this plugin is held to the
-- same rules as the code it plugs into (LuaJIT, implicit self allowed).
std = "luajit"
unused_args = false
self = false

globals = {
    "G_reader_settings",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "unpack",
}

max_line_length = false

-- The test controller evaluates snippets inside the device processes.
files["spec/"] = {
    globals = { "arg" },
}
