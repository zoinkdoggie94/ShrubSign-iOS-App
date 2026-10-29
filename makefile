NAME := ShrubSign
PLATFORM := iphoneos
SCHEMES := ShrubSign
TMP := $(TMPDIR)/$(NAME)
# A stable package checkout location can be restored by GitHub Actions cache.
SOURCE_PACKAGES := $(HOME)/Library/Caches/ShrubSign/SourcePackages
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)

.PHONY: all clean $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf "$(TMP)"
	rm -rf packages
	rm -rf Payload

deps:
	mkdir -p deps
	@if [ ! -s deps/server.crt ]; then curl -fsSL --retry 2 --connect-timeout 12 --max-time 45 -o deps/server.crt https://backloop.dev/backloop.dev-cert.crt; fi
	@if [ ! -s deps/server.pem ]; then \
	  curl -fsSL --retry 2 --connect-timeout 12 --max-time 45 -o deps/server.key1 https://backloop.dev/backloop.dev-key.part1.pem && \
	  curl -fsSL --retry 2 --connect-timeout 12 --max-time 45 -o deps/server.key2 https://backloop.dev/backloop.dev-key.part2.pem && \
	  cat deps/server.key1 deps/server.key2 > deps/server.pem; \
	fi
	rm -f deps/server.key1 deps/server.key2
	echo "*.backloop.dev" > deps/commonName.txt

$(SCHEMES): deps
	xcodebuild \
	    -project ShrubSign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -clonedSourcePackagesDirPath "$(SOURCE_PACKAGES)" \
	    -skipPackagePluginValidation \
	    SHRUBSIGN_BUILD_SHA="$$(git rev-parse --short=12 HEAD 2>/dev/null || echo local)" \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	rm -rf Payload
	rm -rf "$(STAGE)/"
	mkdir -p "$(STAGE)/Payload"

	mv "$(APP)/$@.app" "$(STAGE)/Payload/$@.app"

	chmod -R 0755 "$(STAGE)/Payload/$@.app"
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$@.app"

	cp deps/* "$(STAGE)/Payload/$@.app/" || true

	rm -rf "$(STAGE)/Payload/$@.app/_CodeSignature"

	# Package a real Payload directory. Some IPA tools reject archives created
	# from a symlink named Payload even when unzip can read them.
	rm -rf Payload
	mkdir -p packages
	rm -f "packages/ShrubSign.ipa"
	cd "$(STAGE)" && zip -qry -1 -X "$(CURDIR)/packages/ShrubSign.ipa" Payload

	# Refuse to publish an IPA that cannot be opened or lacks its required bundle files.
	unzip -tq "packages/ShrubSign.ipa"
	zipinfo -1 "packages/ShrubSign.ipa" | grep -Fxq "Payload/$@.app/Info.plist"
	zipinfo -1 "packages/ShrubSign.ipa" | grep -Fxq "Payload/$@.app/$@"
