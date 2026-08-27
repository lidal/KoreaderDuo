local _ = require("gettext")
return {
    name = "duo",
    -- The one place this is written down. `make dist` names the archive
    -- from it, the release workflow refuses to build a tag that disagrees
    -- with it, and the plugin stores read it to decide whether what you
    -- have installed is older than what is published.
    version = "1.0.0",
    fullname = _("Duo (two-device spread)"),
    description = _([[Pairs two KOReader devices into a single two-page spread: one device is the leader and holds the left page, the other follows with the right page. Page turns move the pair. Also does mirror mode, where both devices show the same page.]]),
}
