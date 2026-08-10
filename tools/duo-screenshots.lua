--[[--
Runs Duo on a real book and draws what each device displayed.

    luajit tools/duo-screenshots.lua <book.txt> [device-count]

Two devices, two processes, one Project Gutenberg text laid out identically
on both. After each action the tool asks every device for the text on its
screen and writes it into an HTML page of e-ink-styled frames, ready to be
photographed with a headless browser.

The point of using a real book rather than page numbers: you can read
across the gutter. If the last line of the left screen runs into the first
line of the right one, the spread is genuinely continuous — which is the
thing that would be tedious to verify from numbers alone.

@module tools.duo-screenshots
--]]--

package.path = "./?.lua;./duo.koplugin/?.lua;" .. package.path

local Controller = require("spec/harness/controller")
local Book = require("spec/harness/book")

local BOOK = arg and arg[1] or error("usage: duo-screenshots.lua <book.txt> [devices]")
local DEVICE_COUNT = tonumber(arg and arg[2]) or 2
local PORT = 19995
local OUT_DIR = os.getenv("DUO_OUT") or "/tmp/duo-shots"

-- Loaded here too, so the tool can report the book the devices are reading.
local book = assert(Book.load(BOOK))
print(("book: %s — %d pages of %d×%d"):format(
    book.title, book:getPageCount(), book.columns, book.rows))

os.execute("mkdir -p " .. OUT_DIR)

local controller = Controller.new{ first_port = 18600 }
local names = { "master", "slave", "slave2" }
local devices = {}
for index = 1, DEVICE_COUNT do
    devices[index] = controller:spawn(names[index] or ("slave" .. index), { book = BOOK })
    devices[index].label = names[index] or ("slave" .. index)
end

local function call(device, code) return controller:call(device, code) end

for _, device in ipairs(devices) do
    call(device, "Core:stop('demo')")
    call(device, "Core.settings.token = 'BOOK42'")
    call(device, ("Core.settings.port = %d"):format(PORT))
    call(device, ("Core.settings.peer_port = %d"):format(PORT))
    call(device, "Core.settings.discovery_port = 19996")
    call(device, "Core.settings.mode = 'spread'")
end
call(devices[1], "Core:start('master')")
for index = 2, #devices do
    call(devices[index], ("Core:start('slave', { host = '127.0.0.1', port = %d })"):format(PORT))
end
controller:assertEventually(devices[1], "Core:slaveCount()", #devices - 1, "not everybody connected", 20)
print(("connected: %s"):format(call(devices[1], "Core:getStatusText()")))

--- Reads every screen once the pages have stopped moving.
local function readScreens()
    local socket = require("socket")
    local deadline = socket.gettime() + 3
    local previous, screens
    while socket.gettime() < deadline do
        screens = {}
        for index, device in ipairs(devices) do
            screens[index] = {
                page = tonumber(call(device, "D:getPage()")),
                text = call(device, "D:getPageText()"),
            }
        end
        local signature = ""
        for _, screen in ipairs(screens) do signature = signature .. screen.page .. "," end
        if previous == signature then return screens end
        previous = signature
        socket.sleep(0.08)
    end
    return screens
end

local shots = {}
local function capture(caption, note)
    local screens = readScreens()
    shots[#shots+1] = { caption = caption, note = note, screens = screens }
    local pages = {}
    for _, screen in ipairs(screens) do pages[#pages+1] = screen.page end
    print(("%-38s %s"):format(caption, table.concat(pages, " · ")))
    return screens
end

-- A page a little way in, past the front matter, with prose on it.
call(devices[1], "D:jumpToPage(24)")
local opened = capture("the spread, opened at page 24",
    "Read straight across: the left screen runs into the right one.")

call(devices[1], "D:tapForward()")
local after_one = capture("one tap forward",
    "Both devices moved on by two, so no page is read twice and none is skipped.")

call(devices[1], "D:tapForward()")
capture("and one more")

call(devices[#devices], "D:tapForward()")
capture("a tap on the slave instead",
    "The tap is forwarded to the master, which moves the pair. Only one device ever decides.")

call(devices[1], "Core.settings.mode = 'mirror'; Core:broadcastState()")
capture("mirror mode", "The same page on both, for reading along with somebody else.")

call(devices[1], "Core.settings.mode = 'spread'; Core:broadcastState()")
capture("back to the spread")

--- Does the left screen actually run into the right one?
local function checkContinuity(screens)
    if #screens < 2 then return nil end
    local left_last, right_first
    for line in screens[1].text:gmatch("[^\n]+") do
        if line:match("%S") then left_last = line end
    end
    for line in screens[2].text:gmatch("[^\n]+") do
        if line:match("%S") and not right_first then right_first = line end
    end
    return left_last, right_first
end

local left_last, right_first = checkContinuity(opened)
if left_last then
    print("")
    print("the join, read across the gutter:")
    print("  …" .. left_last)
    print("  " .. right_first .. "…")
end

--------------------------------------------------------------------------
-- Draw it
--------------------------------------------------------------------------

local function escape(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function screenHtml(screen, label, role)
    -- The page is already laid out into lines, so the text goes in verbatim
    -- and CSS is told to respect it. No per-line elements: a block element
    -- inside `white-space: pre` breaks the line a second time.
    return ([[
      <figure class="device">
        <div class="bezel">
          <div class="screen">
            <div class="text">%s</div>
            <div class="foot"><span>%s</span><span>%d / %d</span></div>
          </div>
        </div>
        <figcaption>%s<span class="role">%s</span></figcaption>
      </figure>]]):format(
        escape(screen.text), escape(book.title), screen.page, book:getPageCount(),
        escape(label), escape(role))
end

local function shotHtml(shot)
    local frames = {}
    for index, screen in ipairs(shot.screens) do
        local label = devices[index].label
        local role = index == 1 and "decides what everyone shows" or "shows what it is told"
        frames[#frames+1] = screenHtml(screen, label, role)
    end
    return ([[
    <section class="shot">
      <header><h2>%s</h2>%s</header>
      <div class="devices">%s</div>
    </section>]]):format(
        escape(shot.caption),
        shot.note and ('<p class="note">' .. escape(shot.note) .. "</p>") or "",
        table.concat(frames, "\n"))
end

local STYLE = [[
  :root {
    --paper: #CFCEC7; --paper-edge: #B9B8B1; --ink: #23262C; --ink-soft: #5C6068;
    --bezel: #2A2C31; --bezel-edge: #15171A; --ground: #ECECE8; --rule: #D2D2CB;
    --muted: #6E7269; --faint: #93968C; --signal: #2E7A85;
    --serif: "Iowan Old Style", Charter, "Palatino Linotype", Palatino, Georgia, serif;
    --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--ground); color: var(--ink);
         font-family: var(--serif); padding: 34px 30px; }
  .shot { padding-bottom: 30px; }
  .shot header { max-width: 60ch; margin: 0 auto 20px; text-align: center; }
  h2 { font-size: 1.24rem; font-weight: 600; margin: 0; letter-spacing: -0.01em; }
  .note { font-size: 0.9rem; color: var(--muted); margin: 6px 0 0; }
  .devices { display: flex; justify-content: center; align-items: flex-start; gap: 30px; }
  .device { margin: 0; display: flex; flex-direction: column; gap: 10px; align-items: center; }
  .bezel { background: var(--bezel); border: 1px solid var(--bezel-edge);
           border-radius: 13px; padding: 17px 15px 30px; }
  .screen { width: 300px; height: 400px; background: var(--paper);
            border: 1px solid var(--paper-edge); padding: 18px 18px 8px;
            display: flex; flex-direction: column; overflow: hidden; }
  /* 24 lines at 14.2px have to fit the 352px between the padding and the
     footer, with nothing spilling past the bezel. */
  .text { flex: 1; font-size: 10.5px; line-height: 1.35; color: var(--ink);
          white-space: pre-wrap; font-family: var(--serif); overflow: hidden; }
  .foot { display: flex; justify-content: space-between; font-family: var(--mono);
          font-size: 8.5px; color: var(--ink-soft); border-top: 1px solid rgba(35,38,44,0.2);
          padding-top: 6px; font-variant-numeric: tabular-nums; letter-spacing: 0.03em; }
  figcaption { font-family: var(--mono); font-size: 10px; letter-spacing: 0.12em;
               text-transform: uppercase; color: var(--muted); text-align: center;
               display: flex; flex-direction: column; gap: 3px; }
  .role { color: var(--faint); letter-spacing: 0.06em; text-transform: none;
          font-family: var(--serif); font-size: 11px; }
]]

local function writePage(path, body, width)
    local file = assert(io.open(path, "w"))
    file:write(([[<!doctype html>
<html><head><meta charset="utf-8"><title>KOReader Duo</title>
<style>%s
body { width: %dpx; }
</style></head><body>
%s
</body></html>
]]):format(STYLE, width, body))
    file:close()
end

local frame_width = 30 * 2 + DEVICE_COUNT * 332 + (DEVICE_COUNT - 1) * 30

for index, shot in ipairs(shots) do
    writePage(("%s/shot-%d.html"):format(OUT_DIR, index), shotHtml(shot), frame_width)
end

local all = {}
for _, shot in ipairs(shots) do all[#all+1] = shotHtml(shot) end
writePage(OUT_DIR .. "/all.html", table.concat(all, "\n"), frame_width)

-- The three consecutive states, stacked: one picture that shows a turn
-- moving both devices on by two.
local sequence = {}
for index = 1, math.min(3, #shots) do
    sequence[#sequence+1] = shotHtml(shots[index])
end
writePage(OUT_DIR .. "/sequence.html", table.concat(sequence, "\n"), frame_width)

print("")
print(("wrote %d pages to %s"):format(#shots + 2, OUT_DIR))
controller:shutdown()
