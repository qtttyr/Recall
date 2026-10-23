PROJECT := Recall.xcodeproj
SCHEME := Recall
DESTINATION := platform=macOS,arch=arm64
ARCHS := arm64
DERIVED := .build/DerivedData

.PHONY: build test clean run release dmg install

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		ARCHS=$(ARCHS) \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO \
		build

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		ARCHS=$(ARCHS) \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO \
		test

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED) \
		clean
	rm -rf $(DERIVED) dist

run: build
	open "$(DERIVED)/Build/Products/Debug/Recall.app"

release dmg:
	chmod +x scripts/package_release.sh
	./scripts/package_release.sh

install: build
	rm -rf /Applications/Recall.app
	cp -R "$(DERIVED)/Build/Products/Debug/Recall.app" /Applications/Recall.app
	xattr -cr /Applications/Recall.app 2>/dev/null || true
	codesign --force --deep --sign - /Applications/Recall.app
	@echo "Installed to /Applications/Recall.app (quarantine removed)"
