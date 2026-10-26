# The native Duo reader — development tasks.
#
#   make test      run the suite (unit, app, two-process spread)
#   make check     syntax-check every Lua file and shell script
#   make run       start the app headlessly, against ./books
#   make dist      build the KUAL extension archive
#
# The plugin's own Makefile is one directory up and is untouched by any of
# this. Nothing here builds for a device: that needs koxtoolchain and
# koreader-base, which is Stage 1 of FEASIBILITY.md and is not done.

LUA ?= luajit

# The app, then the repository root (for spec/testrunner and spec/harness),
# then the plugin's own modules — which are required unchanged.
LUA_PATH_SETTING := ./?.lua;../?.lua;../duo.koplugin/?.lua;;

SPECS := spec/engine_spec.lua spec/touch_spec.lua spec/app_spec.lua spec/spread_spec.lua
SOURCES := $(wildcard app/*.lua app/*/*.lua spec/*.lua)
SHELLS := $(wildcard kual/duo/*.sh)

.PHONY: test check run dist clean

test: check
	@failed=0; \
	for spec in $(SPECS); do \
		echo "==> $$spec"; \
		LUA_PATH="$(LUA_PATH_SETTING)" $(LUA) $$spec || failed=1; \
	done; \
	if [ $$failed -ne 0 ]; then echo "\nSUITE FAILED"; exit 1; fi; \
	echo "\nAll suites passed."

#[[
# Syntax, including the shell scripts.
#
# The scripts are checked because they are the only part of this that a
# device runs before any Lua does: a typo in run.sh is a reader that stops
# its own framework and then fails to start anything, which is a blank
# screen and a confused owner.
#]]
check:
	@for file in $(SOURCES); do \
		$(LUA) -bl $$file >/dev/null 2>&1 || luac5.1 -p $$file || \
			{ echo "syntax error in $$file"; exit 1; }; \
	done
	@for file in $(SHELLS); do \
		sh -n $$file || { echo "syntax error in $$file"; exit 1; }; \
	done
	@echo "syntax OK"
	@command -v luacheck >/dev/null 2>&1 && luacheck --quiet app spec || \
		echo "(luacheck not installed, skipping lint)"

run:
	@mkdir -p books
	DUO_BOOKS=books LUA_PATH="$(LUA_PATH_SETTING)" $(LUA) app/boot.lua --headless

#[[
# The KUAL extension, as it lands in `extensions/`.
#
# The interpreter and koreader-base's libraries are NOT in here: they are
# built per device and have to be dropped in beside the Lua. The archive is
# the app, and the README says what else has to join it.
#]]
dist: check
	@rm -rf dist && mkdir -p dist/duo
	@cp -r app dist/duo/
	@cp kual/duo/* dist/duo/
	@cd dist && zip -qr duo-kual.zip duo
	@echo "dist/duo-kual.zip  (needs luajit + koreader-base libs added)"

clean:
	rm -rf dist
	rm -f /tmp/duonative-*.log /tmp/duonative-settings.lua
