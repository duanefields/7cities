# Seven Cities of Gold — macOS port
#
# Requires macOS with Swift 6. Nothing else: no emulator, no Python.

PKG := SevenCitiesCore

.PHONY: all extract run test build app clean help

help:
	@echo "make extract   decode your disk images in d64/ into assets/"
	@echo "make run       launch the map viewer"
	@echo "make test      run the test suite"
	@echo "make build     compile without running"
	@echo "make app       build the Mac app bundle"
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

# The app is a thin wrapper around the same package; open app/SevenCities.xcodeproj
# to work on it in Xcode.
app:
	xcodebuild -project app/SevenCities.xcodeproj -scheme SevenCities \
		-configuration Release build

clean:
	swift package --package-path $(PKG) clean
	rm -rf assets
