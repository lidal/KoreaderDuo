--[[--
Duo's engine, hosted by this app instead of by KOReader.

This is the file the whole study was about. `duo/core.lua` reaches its host
through exactly three doors -- a hooks table, a reader binding of eight
methods, and a browser binding of six -- and KOReader is merely the host
that answers them today. Answer them from here and the existing engine
drives this app: the handshake, the signing, the roles, the spread
arithmetic, the typography matching, the step-back-don't-hang-up behaviour
on a silent line. None of it is rewritten. It is required.

**Serial only.** The network transports are not wired up, and the hooks
that exist for them are stubbed to say so rather than left absent: a
missing hook is a silent no-op inside the engine, and "the radio quietly
did nothing" is a worse thing to debug than "the radio is not here". The
engine itself needs no convincing -- `transport = "serial"` is a setting it
already has.

**The chokepoints.** Views never move themselves. A reader's tap arrives at
`onTurnRequest`, which offers the turn to the engine; if the engine takes
it, nothing moves here until the engine says so, because with two devices
the leader must advance by the width of the spread and a follower's tap is
a request that may be refused. The same for the shelf. That is the
plugin's own design and it is the right one.

@module duonative.duohost
--]]--

local Core = require("duo/core")
local Spread = require("duo/spread")
local EngineApi = require("app/engine/api")

local DuoHost = {}
DuoHost.__index = DuoHost

--[[--
@tparam table options
    app      the application (see `main.lua`) -- asked for the live views
    store    a `store.lua` instance, for persistence
    log      function(...) optional
--]]--
function DuoHost.new(options)
    options = options or {}
    local self = setmetatable({
        app = options.app,
        store = options.store,
        notices = {},
        log_lines = {},
    }, DuoHost)
    self:configure()
    return self
end

--------------------------------------------------------------------------
-- The hooks
--------------------------------------------------------------------------

--[[--
Hands the engine everything it may ask the host for.

Serial-only, so the radio hooks answer honestly and do nothing. The rest
are real: saving settings, telling the reader something, opening a book
the other device asked for, going to sleep because the other device did.
--]]--
function DuoHost:configure()
    local app = self.app
    local store = self.store

    Core:configure{
        settings = store and store:get("duo", {}) or {},
        hooks = {
            log = function(...) self:onLog(...) end,
            save = function(settings)
                if not store then return end
                store:set("duo", settings)
                store:flush()
            end,
            notify = function(text) self:notify(text) end,
            alert = function(text) self:notify(text) end,
            onChanged = function() if app then app:markDirty() end end,

            openDocument = function(file, msg) return app and app:openBook(file, msg) end,
            closeDocument = function() return app and app:closeBook() end,
            reloadDocument = function() return app and app:reloadBook() end,

            getBookDir = function() return app and app:bookDir() end,
            listFolder = function(path) return app and app:listFolder(path) end,
            getTempDir = function() return os.getenv("TMPDIR") or "/tmp" end,
            defaultDeviceName = function() return app and app:deviceName() or "duo" end,

            sleepDevice = function() return app and app:sleep() end,
            setAwake = function(awake) return app and app:setAwake(awake) end,
            getFrontlight = function() return app and app:getFrontlight() end,
            applyFrontlight = function(wanted) return app and app:applyFrontlight(wanted) end,

            --[[
            There is no radio here, and saying so beats doing nothing.

            The engine guards each of these, so leaving them out would work
            -- and would mean a Wi-Fi code path that silently succeeded at
            nothing. A hook that records being asked is a hook that shows
            up in the log when somebody has set `transport` to the wrong
            thing, which is the actual failure this app can have.
            ]]
            wakeNetwork = function() return self:noRadio("wakeNetwork") end,
            setRadioAwake = function() return self:noRadio("setRadioAwake") end,
            radioIsAwake = function() self:noRadio("radioIsAwake") return false end,
            openFirewall = function() return self:noRadio("openFirewall") end,
            closeFirewall = function() return self:noRadio("closeFirewall") end,
            reviveDirectLink = function() return self:noRadio("reviveDirectLink") end,
            directLinkStatus = function()
                self:noRadio("directLinkStatus")
                return { ok = false, reason = "this build has no radio" }
            end,

            switchTransport = function(to, ours) return self:onPeerSwitch(to, ours) end,
            askForToken = function() return self:notify("Duo needs a pairing code") end,
            shelvesDiffer = function(count, bytes)
                return self:notify(("%d books, %d bytes differ"):format(count or 0, bytes or 0))
            end,
        },
    }

    -- The wire is the only link, so say so once rather than leaving the
    -- engine's default of TCP to fail later and less clearly.
    Core:set("transport", Core.TRANSPORT_SERIAL)
    return self
end

function DuoHost:noRadio(which)
    self:onLog("asked for", which, "but this build has no radio")
    return false
end

function DuoHost:onLog(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[#parts+1] = tostring(select(index, ...))
    end
    local line = table.concat(parts, " ")
    self.log_lines[#self.log_lines+1] = line
    -- Bounded: a log that grows without limit on a device with 512MB is a
    -- reader that stops after a long session.
    if #self.log_lines > 500 then table.remove(self.log_lines, 1) end
    return line
end

function DuoHost:logTail(count)
    local out = {}
    for index = math.max(#self.log_lines - (count or 20) + 1, 1), #self.log_lines do
        out[#out+1] = self.log_lines[index]
    end
    return out
end

--- Something to put on screen. Kept, so the suite can assert on it.
function DuoHost:notify(text)
    self.notices[#self.notices+1] = tostring(text)
    if self.app then self.app:showNotice(tostring(text)) end
    return true
end

function DuoHost:onPeerSwitch(to, ours)
    self:onLog("peer switched transport to", tostring(to), "ours:", tostring(ours))
    return true
end

--------------------------------------------------------------------------
-- The reader binding: eight methods
--------------------------------------------------------------------------

--[[--
Hands the open book to the engine.

`turnRelative` is the unclaimed turn -- the real one, already multiplied by
the width of the spread. It must not go back through the delegate or the
engine would be asked about its own decision, which is an infinite loop
with a page number in it. `local_only` is what prevents that, and it is the
same trick `main.lua` plays by calling KOReader's unwrapped method.
--]]--
function DuoHost:attachReader(reader)
    if not reader then return end
    self.reader = reader
    self.reader_binding = {
        getPage = function()
            local doc = reader:document()
            return doc and doc:page() or nil
        end,
        getPageCount = function()
            local doc = reader:document()
            return doc and doc:pageCount() or nil
        end,
        -- One page per screen, always. This app's whole premise is that the
        -- second page is on the other device.
        getPagesPerView = function() return 1 end,
        gotoPage = function(page) return reader:gotoPage(page) end,
        turnRelative = function(diff)
            return reader:turn(diff, { local_only = true })
        end,
        getTypography = function() return self:typographySnapshot() end,
        applyTypography = function(settings) return self:applyTypography(settings) end,
        getDocument = function()
            local doc = reader:document()
            if not doc then return nil end
            local props = doc:props()
            return {
                file = doc.path,
                title = props.title,
                -- The engine's fingerprint, which is a better digest than a
                -- checksum of the file: two devices with the same bytes can
                -- still paginate differently, and this is the thing that
                -- notices.
                digest = doc:fingerprint(),
            }
        end,
    }
    Core:attachReader(self.reader_binding)
    return self.reader_binding
end

function DuoHost:detachReader()
    Core:detachReader(self.reader_binding)
    self.reader, self.reader_binding = nil, nil
end

--[[--
Typography, in the engine's vocabulary.

The engine's names are KOReader's `configurable` names, and its values are
*encoded strings* -- that is the wire format, not an implementation detail:
numbers and strings stringified, booleans as "1"/"0", pairs joined with a
comma. `duo/typography.lua` owns that encoding and this uses it rather than
repeating it, because two copies of a wire format are two things to keep in
step with each other and with the far end.

So the names do not line up with `engine/api.lua`'s, and translating is
the job:

    font_face         <-> face
    font_size         <-> size
    font_base_weight  <-> weight
    line_spacing      <-> line_spacing
    word_spacing      <-> word_spacing
    h_page_margins    <-> { margin_left, margin_right }   (a pair)
    t_page_margin     <-> margin_top
    b_page_margin     <-> margin_bottom
    embedded_css      <-> embedded_styles                  (note the name)
    embedded_fonts    <-> embedded_fonts

Getting `embedded_css` wrong as `embedded_styles` is silent: the engine
matches the settings it is given and simply never mentions the one whose
name nobody recognises, so the two devices agree about everything except
whether the book's own stylesheet is in use -- and then paginate
differently for a reason no setting explains.

**Compatibility is with this app, not with the plugin.** Both ends of a
pair run this frontend, so the vocabulary only has to be self-consistent.
A pair made of one KOReader-plus-plugin and one of these would need the
value shapes to agree exactly too -- `word_spacing` is a pair in KOReader
and a number here, for one -- and that is not a thing this app claims to
do.
--]]--
local Typography = require("duo/typography")

local BRIDGE = {
    font_face = {
        get = function(layout) return layout.face end,
        set = function(layout, raw) layout.face = tostring(raw) end,
    },
    font_size = {
        get = function(layout) return layout.size end,
        set = function(layout, raw) layout.size = tonumber(raw) or layout.size end,
    },
    font_base_weight = {
        get = function(layout) return layout.weight end,
        set = function(layout, raw) layout.weight = tonumber(raw) or layout.weight end,
    },
    line_spacing = {
        get = function(layout) return layout.line_spacing end,
        set = function(layout, raw) layout.line_spacing = tonumber(raw) or layout.line_spacing end,
    },
    word_spacing = {
        get = function(layout) return layout.word_spacing end,
        set = function(layout, raw) layout.word_spacing = tonumber(raw) or layout.word_spacing end,
    },
    h_page_margins = {
        get = function(layout) return { layout.margin_left, layout.margin_right } end,
        set = function(layout, raw)
            if type(raw) ~= "table" then return end
            layout.margin_left = tonumber(raw[1]) or layout.margin_left
            layout.margin_right = tonumber(raw[2]) or layout.margin_right
        end,
    },
    t_page_margin = {
        get = function(layout) return layout.margin_top end,
        set = function(layout, raw) layout.margin_top = tonumber(raw) or layout.margin_top end,
    },
    b_page_margin = {
        get = function(layout) return layout.margin_bottom end,
        set = function(layout, raw) layout.margin_bottom = tonumber(raw) or layout.margin_bottom end,
    },
    embedded_css = {
        get = function(layout) return layout.embedded_styles end,
        set = function(layout, raw) layout.embedded_styles = raw == true or raw == 1 end,
    },
    embedded_fonts = {
        get = function(layout) return layout.embedded_fonts end,
        set = function(layout, raw) layout.embedded_fonts = raw == true or raw == 1 end,
    },
}

DuoHost.BRIDGE = BRIDGE

--- This device's typography, encoded as the engine sends it.
function DuoHost:typographySnapshot()
    local layout = self.reader and self.reader:getLayout()
    if not layout then return nil end
    local out = {}
    for key, bridge in pairs(BRIDGE) do
        out[key] = Typography.encodeValue(bridge.get(layout))
    end
    return out
end

--[[--
Applies what the other device sent.

@tparam table settings key -> encoded string
@tparam[opt] table refused the engine's per-key count of settings that
    would not take. Unused here: every setting this app has, it can set --
    there is no engine refusing a style change and putting it back, which
    is what that mechanism exists to bound on KOReader.
@treturn table the keys that actually changed, which the engine counts and
    names. An array, and never a boolean: the engine takes `#applied`.
--]]--
function DuoHost:applyTypography(settings, refused) -- luacheck: ignore refused
    local applied = {}
    if not self.reader or not settings then return applied end
    local layout = self.reader:getLayout()
    if not layout then return applied end

    local wanted = {}
    for key, value in pairs(layout) do wanted[key] = value end

    local touched = {}
    for key, bridge in pairs(BRIDGE) do
        local encoded = settings[key]
        if encoded ~= nil then
            local template = bridge.get(layout)
            local decoded = Typography.decodeValue(encoded, template)
            if decoded ~= nil then
                bridge.set(wanted, decoded)
                touched[#touched+1] = key
            end
        end
    end

    if EngineApi.sameLayout(wanted, layout) then return applied end
    self.reader:applyLayout(wanted)

    -- Only the keys whose value really moved, not every key that was sent:
    -- the engine notifies the reader with this list, and naming settings
    -- that were already right is how "matched the font size" appears on a
    -- screen where nothing happened.
    local now = self.reader:getLayout()
    for _, key in ipairs(touched) do
        local bridge = BRIDGE[key]
        if Typography.encodeValue(bridge.get(now))
            ~= Typography.encodeValue(bridge.get(layout)) then
            applied[#applied+1] = key
        end
    end
    table.sort(applied)
    return applied
end

--------------------------------------------------------------------------
-- The browser binding: six methods
--------------------------------------------------------------------------

function DuoHost:attachBrowser(library)
    if not library then return end
    self.library = library
    self.browser_binding = {
        getState = function() return library:getState() end,
        goToPage = function(page) return library:goToPage(page) end,
        getFiles = function() return library:getFiles() end,
        refresh = function() return library:refresh() end,
        changeDir = function(path) return library:changeDir(path) end,
        setPerPage = function(perpage, cols, rows)
            return library:setPerPage(perpage, cols, rows)
        end,
    }
    Core:attachBrowser(self.browser_binding)
    return self.browser_binding
end

function DuoHost:detachBrowser()
    Core:detachBrowser(self.browser_binding)
    self.library, self.browser_binding = nil, nil
end

--------------------------------------------------------------------------
-- What the views ask
--------------------------------------------------------------------------

--- True when the engine took the turn, so the view must not move.
function DuoHost:onTurnRequest(diff)
    return Core:handleRelativeTurn(diff) and true or false
end

function DuoHost:onLibraryTurn(diff)
    return Core:handleBrowserTurn(diff) and true or false
end

--- Tells the engine the page moved, however it moved.
function DuoHost:onPageChanged(page)
    return Core:onPageChanged(page)
end

--[[--
Tells the engine a relayout happened.

Reported as a page change because that is what it is from the pair's point
of view -- the book is a different length now and the follower's page
number means something else. The engine's typography matching will have
been the cause most of the time; when it was this device's own reader, this
is how the other one finds out.
--]]--
function DuoHost:onReflow(doc)
    if not doc then return false end
    self:onLog("relayout:", doc:fingerprint())
    return Core:onPageChanged(doc:page())
end

--------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------

function DuoHost:start(role)
    return Core:start(role or Core:get("role") or "leader")
end

function DuoHost:stop(reason)
    return Core:stop(reason or "asked to")
end

function DuoHost:poll() return Core:poll() end
function DuoHost:isConnected() return Core:isConnected() end

--[[--
"12–13", for the footer.

Straight from the engine's own arithmetic rather than worked out here. The
spread's shape is the engine's business and duplicating it is how the two
come to disagree.
--]]--
function DuoHost:spreadLabel()
    if not Core:isConnected() then return nil end
    local doc = self.reader and self.reader:document()
    local page = doc and doc:page()
    if not page then return nil end
    return Spread.describeLayout(page, 1, {
        mode = Core:get("mode"),
        reverse = Core:get("reverse"),
        page_count = doc:pageCount(),
        pages_per_view = 1,
    })
end

DuoHost.Core = Core

return DuoHost
