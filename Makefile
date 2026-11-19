ifeq ($(shell xcodebuild -version >/dev/null 2>&1; echo $$?),1)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

.PHONY: app debug run status selftest screenshots test clean

BIN = build/ChargeCap.app/Contents/MacOS/ChargeCap

app:
	Scripts/bundle.sh release

debug:
	Scripts/bundle.sh debug

run: app
	-pkill -x ChargeCap
	open build/ChargeCap.app

status: app
	$(BIN) --status

selftest: app
	$(BIN) --selftest build/selftest

screenshots: app
	$(BIN) --selftest build/selftest --screenshots docs/screenshots

test: selftest

clean:
	rm -rf .build build
