local _ = require("gettext")
return {
    name = "duo",
    fullname = _("Duo (two-device spread)"),
    description = _([[Pairs two KOReader devices into a single two-page spread: one device is the leader and holds the left page, the other follows with the right page. Page turns move the pair. Also does mirror mode, where both devices show the same page.]]),
}
