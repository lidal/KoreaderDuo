--[[--
One simulated KOReader, running the real Duo plugin.

Builds the stub environment, loads `duo.koplugin/main.lua` exactly the way
KOReader's plugin loader does (a `dofile` with the plugin directory on
`package.path`), instantiates it against a fake ReaderUI, and exposes the
handful of actions a test wants to perform: turn a page, open a book, pump
the event loop.

@module spec.harness.instance
--]]--

local Env = require("spec/harness/env")
local Reader = require("spec/harness/reader")

local Instance = {}
Instance.__index = Instance

--[[--
Boots a simulated device.

@tparam table options
    name        device name, as the other device will see it
    plugin_dir  path to duo.koplugin (default "duo.koplugin")
    page_count  pages in the open document
    no_document start in the file manager, with no book open
--]]--
function Instance.new(options)
    options = options or {}
    local env = Env.install{
        device_name = options.name or "TestReader",
        data_dir = options.data_dir,
        debug = options.debug,
    }

    local plugin_dir = options.plugin_dir or "duo.koplugin"
    package.path = plugin_dir .. "/?.lua;" .. package.path

    local Duo = dofile(plugin_dir .. "/main.lua")
    local Core = require("duo/core")

    local self = setmetatable({
        env = env,
        UIManager = env.UIManager,
        Event = env.Event,
        Core = Core,
        Duo = Duo,
        name = options.name or "TestReader",
    }, Instance)

    if options.file_manager then
        self:openFileManager(options)
    elseif not options.no_document then
        self:openDocument(options)
    else
        self.plugin = Duo:new{ ui = { menu = { registerToMainMenu = function() end } } }
    end
    return self
end

--- Opens a document, rebuilding the plugin instance the way KOReader does
-- on every document switch — which is what makes a connection that lives in
-- the plugin instance a bug, and one that lives in the engine correct.
function Instance:openDocument(options)
    options = options or {}
    if self.plugin then
        self.plugin:onCloseDocument()
    end
    -- DUO_BOOK points at a plain-text book to lay out and display, which is
    -- how the demo puts real prose on the two screens.
    local book
    local book_path = options.book_path or os.getenv("DUO_BOOK")
    if book_path and book_path ~= "" then
        local Book = require("spec/harness/book")
        local loaded, err = Book.load(book_path)
        if not loaded then error("could not load " .. book_path .. ": " .. tostring(err)) end
        book = loaded
    end

    self.ui = Reader.newUI{
        Event = self.Event,
        document = Reader.newDocument{
            file = options.file,
            book = book,
            page_count = options.page_count,
            pages_per_view = options.pages_per_view,
        },
        title = options.title or (book and book.title),
        digest = options.digest,
    }
    self.plugin = self.Duo:new{ ui = self.ui }
    self.ui:registerPlugin(self.plugin)
    self.plugin:onReaderReady()
    return self
end

--- Closes any document and shows the file browser, as KOReader does when
-- you leave a book.
function Instance:openFileManager(options)
    options = options or {}
    if self.plugin then
        self.plugin:onCloseWidget()
    end
    self.ui = Reader.newFileManager{
        Event = self.Event,
        path = options.path,
        items = options.items,
        folders = options.folders,
        perpage = options.perpage,
        real_folder = options.real_folder,
    }
    self.plugin = self.Duo:new{ ui = self.ui }
    self.ui:registerPlugin(self.plugin)
    return self
end

--- What the file browser is showing on this screen.
function Instance:visibleBooks()
    if not self.ui.file_chooser then return {} end
    return self.ui.file_chooser:visibleNames()
end

--- Runs the UI loop for `seconds`, or until `condition` becomes true.
function Instance:pump(seconds, condition)
    local socket = require("socket")
    local deadline = socket.gettime() + (seconds or 0)
    repeat
        self.UIManager:pump()
        if condition and condition() then return true end
        socket.sleep(0.002)
    until socket.gettime() >= deadline
    return condition and condition() or false
end

--- A tap in the "next page" corner, taking the same path a real one does.
function Instance:tapForward()
    self.ui.paging:onGotoViewRel(1)
end

function Instance:tapBack()
    self.ui.paging:onGotoViewRel(-1)
end

--- A jump from the table of contents or the go-to dialog.
function Instance:jumpToPage(page)
    self.ui:handleEvent(self.Event:new("GotoPage", page))
end

function Instance:getPage()
    return self.ui.paging.current_page
end

--- What is actually on this device's screen, when a real book is loaded.
function Instance:getPageText()
    return self.ui.document:getPageText(self:getPage())
end

function Instance:getStatus()
    return self.Core:getStatusText()
end

--- Text of everything the plugin put on screen since the last call.
function Instance:drainMessages()
    local messages = {}
    for _, entry in ipairs(self.UIManager:drainShownLog()) do
        messages[#messages+1] = entry.text
    end
    return messages
end

return Instance
