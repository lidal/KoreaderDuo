--[[--
A book, written on the spot.

Generated rather than checked in: a fixture that lives in the repository
is a fixture somebody edits by accident, and this one's exact length is
load-bearing -- several tests assert page counts, and a stray word would
move them all.

@module duonative.spec.fixture
--]]--

local Fixture = {}

--- Deterministic filler. The same seed gives the same book, every run.
local WORDS = {
    "the", "reader", "turned", "a", "page", "and", "the", "other",
    "device", "followed", "without", "being", "asked", "which", "is",
    "the", "whole", "point", "of", "it", "paper", "ink", "light",
}

function Fixture.text(paragraphs, words_each)
    paragraphs = paragraphs or 80
    words_each = words_each or 60
    local out = {}
    local counter = 0
    for index = 1, paragraphs do
        if index % 7 == 1 then
            out[#out+1] = ("# Chapter %d"):format(math.floor(index / 7) + 1)
            out[#out+1] = ""
        end
        local words = {}
        for _ = 1, words_each do
            counter = counter + 1
            words[#words+1] = WORDS[(counter % #WORDS) + 1]
        end
        out[#out+1] = table.concat(words, " ")
        out[#out+1] = ""
    end
    return table.concat(out, "\n")
end

--- Writes the book somewhere temporary and hands back the path.
function Fixture.book(name, paragraphs, words_each)
    local path = ("%s/duonative-%s.txt"):format(
        os.getenv("TMPDIR") or "/tmp", name or "book")
    local handle = assert(io.open(path, "w"))
    handle:write(Fixture.text(paragraphs, words_each))
    handle:close()
    return path
end

return Fixture
