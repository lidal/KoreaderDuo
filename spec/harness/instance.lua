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
        --[[
        The hook that matches what is actually on screen. KOReader takes a
        reader down through onCloseDocument and the file manager down through
        onCloseWidget, and it is the second that makes the plugin let go of
        the file browser. Calling the reader's hook on the way out of the
        file manager left the engine believing a browser was still attached
        after the book had opened -- which is not a state a real device is
        ever in, and it hid a bug that real devices hit.
        ]]
        if self.ui and self.ui.file_chooser then
            self.plugin:onCloseWidget()
        else
            self.plugin:onCloseDocument()
        end
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

--[[--
Makes this device genuinely not have a file.

Two simulated devices share one filesystem, so a follower told to open the
leader's book would otherwise just open it off the disk and nothing would
ever be sent. This is how a test says "this book is not on this device":
the path stops existing as far as this device can tell.
--]]--
function Instance:doesNotHave(path)
    self.env.lfs.missing[path] = true
end

--- Opens a book the way a tap in the file browser does.
function Instance:openFile(path)
    if self.ui and type(self.ui.openFile) == "function" then
        return self.ui:openFile(path)
    end
    return false
end

--- How big a file is on this device, for comparing the two.
function Instance:sizeOf(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local size = handle:seek("end")
    handle:close()
    return size
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
--[[--
Opens one of the library's own views on this device, over the browser.

Duo binds to whatever list is on screen, and a view is what a skin like
ZenOS puts there instead of a folder. The plugin is told the same way
KOReader tells it -- the browser binding is rebuilt -- so a test drives the
path a reader walks rather than reaching into the engine.
--]]--
function Instance:openLibraryView(kind, options)
    local Reader = require("spec/harness/reader")
    local menu = Reader.openLibraryView(self.ui, kind, options)
    if self.plugin then self.plugin:bindBrowser() end
    return menu
end

function Instance:closeLibraryView()
    local Reader = require("spec/harness/reader")
    Reader.closeLibraryView(self.ui)
    if self.plugin then self.plugin:bindBrowser() end
end

--[[--
Dismisses whatever is still on screen.

Tests that assert "nothing is asking me anything" need a known starting
point, and a dialog left up by a test that failed halfway through is not
one. Nothing is cancelled or confirmed here -- the widgets are simply taken
off the screen, which is all a later test cares about.
--]]--
function Instance:clearScreen()
    for widget in pairs(self.UIManager.shown) do
        self.UIManager.shown[widget] = nil
    end
end

--[[--
The dialog on screen right now, so a test can answer one the way a finger
would rather than only assert that it appeared.

`shown` is a set, and set iteration has no order; every test that uses this
has exactly one dialog up, which is the only situation in which "the dialog"
means anything.

@tparam[opt] string class_name  "InputDialog" by default
--]]--
function Instance:currentDialog(class_name)
    class_name = class_name or "InputDialog"
    for widget in pairs(self.UIManager.shown) do
        if widget.class_name == class_name then return widget end
    end
    return nil
end

--[[--
Types into the dialog on screen and presses one of its buttons.

@tparam ?string text         what to type, or nil to leave the box alone
@tparam string button_text   which button to press
@treturn boolean  whether there was such a dialog with such a button
--]]--
function Instance:answerDialog(text, button_text)
    local dialog = self:currentDialog("InputDialog")
    if not dialog then return false end
    if text ~= nil then dialog:setInputText(text) end
    for _, row in ipairs(dialog.buttons or {}) do
        for _, button in ipairs(row) do
            if button.text == button_text and button.callback then
                button.callback()
                return true
            end
        end
    end
    return false
end

function Instance:drainMessages()
    local messages = {}
    for _, entry in ipairs(self.UIManager:drainShownLog()) do
        messages[#messages+1] = entry.text
    end
    return messages
end

return Instance
