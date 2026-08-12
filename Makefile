# Seven Cities of Gold — macOS port
#
# Requires macOS with Swift 6. Nothing else: no emulator, no Python.

PKG := SevenCitiesCore

.PHONY: all extract run test build clean help

help:
	@echo "make extract   decode your disk images in d64/ into assets/"
	@echo "make run       launch the map viewer"
	@echo "make test      run the test suite"
	@echo "make build     compile without running"
	@echo "make clean     remove build products and extracted assets"

all: extract run

build:
	swift build --package-path $(PKG)

extract: build
	swift run --package-path $(PKG) Extract .

run: build
	swift run --package-path $(PKG) MapViewer assets

test:
	swift test --package-path $(PKG)

clean:
	swift package --package-path $(PKG) clean
	rm -rf assets
