# KOReader Duo — development tasks.
#
#   make test       run everything (unit, plugin, two-process integration)
#   make check      syntax-check every Lua file
#   make install KOREADER=/path/to/koreader   copy the plugin into KOReader
#
# KOReader runs LuaJIT, so that is the default interpreter here; the suite
# also passes on plain lua5.1.

LUA ?= luajit
LUA_PATH_SETTING := ./?.lua;./duo.koplugin/?.lua;;
SPECS := spec/protocol_spec.lua spec/link_spec.lua spec/plugin_spec.lua \
         spec/integration_spec.lua spec/serial_spec.lua \
         spec/typography_spec.lua spec/booktransfer_spec.lua spec/browser_spec.lua \
         spec/library_spec.lua spec/epubstub_spec.lua spec/frontlight_spec.lua \
         spec/directlink_spec.lua spec/directlink_net_spec.lua spec/log_spec.lua
SOURCES := $(wildcard duo.koplugin/*.lua duo.koplugin/duo/*.lua spec/*.lua spec/harness/*.lua)

.PHONY: test check install clean real

test: check
	@failed=0; \
	for spec in $(SPECS); do \
		echo "==> $$spec"; \
		LUA_PATH="$(LUA_PATH_SETTING)" $(LUA) $$spec || failed=1; \
	done; \
	if [ $$failed -ne 0 ]; then echo "\nSUITE FAILED"; exit 1; fi; \
	echo "\nAll suites passed."

check:
	@for file in $(SOURCES); do \
		$(LUA) -bl $$file >/dev/null 2>&1 || luac5.1 -p $$file || \
			{ echo "syntax error in $$file"; exit 1; }; \
	done
	@echo "syntax OK"
	@command -v luacheck >/dev/null 2>&1 && luacheck --quiet duo.koplugin spec || \
		echo "(luacheck not installed, skipping lint)"

#[[
# The same plugin, against two KOReaders that are really running.
#
# Slow, and it needs a KOReader to point at, so it is deliberately not part
# of `make test`. What it is for is the gap the simulated devices cannot
# close: how a real crengine moves a page across a relayout, what a real
# widget does when it is torn down, whether a screen that cannot be made to
# crash here crashes there.
#
#   make real KOREADER=/path/to/koreader
#]]
real:
ifndef KOREADER
	$(error set KOREADER to a KOReader directory, e.g. make real KOREADER=/opt/koreader)
endif
	@command -v xvfb-run >/dev/null 2>&1 || \
		{ echo "xvfb-run is needed to run KOReader without a display"; exit 1; }
	KOREADER_DIR="$(KOREADER)" LUA_PATH="$(LUA_PATH_SETTING)" $(LUA) spec/real_spec.lua

install:
ifndef KOREADER
	$(error Set KOREADER to your KOReader directory, e.g. make install KOREADER=/mnt/us/koreader)
endif
	mkdir -p "$(KOREADER)/plugins"
	cp -r duo.koplugin "$(KOREADER)/plugins/"
	@echo "Installed to $(KOREADER)/plugins/duo.koplugin"

clean:
	rm -f /tmp/duo-*.log
