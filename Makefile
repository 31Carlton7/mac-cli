PREFIX ?= /usr/local

build:
	swift build -c release

test:
	swift test

install: build
	install -d $(PREFIX)/bin
	install .build/release/mac $(PREFIX)/bin/mac

smoke: build
	./scripts/smoke.sh

.PHONY: build test install smoke
