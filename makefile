NAME := ShrubSign
PLATFORM := iphoneos
SCHEMES := ShrubSign
# Stable path across hosted builds permits reuse of compiled intermediates.
TMP ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/$(NAME),$(TMPDIR)/$(NAME))
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
	@mkdir -p deps
	@# The publicly hosted backloop.dev cert/key files were withdrawn.
	@# Never make an IPA build depend on those obsolete download links.
	@rm -f deps/server.key1 deps/server.key2
	@if [ -s deps/server.crt ] && [ -s deps/server.pem ]; then \
	  openssl x509 -in deps/server.crt -noout >/dev/null && \
	  openssl pkey -in deps/server.pem -noout >/dev/null || { \
	    echo "ERROR: The supplied local HTTPS certificate/key files are invalid." >&2; \
	    exit 1; \
	  }; \
	  if [ ! -s deps/commonName.txt ]; then echo "127.0.0.1" > deps/commonName.txt; fi; \
	  echo "Using supplied local HTTPS server certificate files."; \
	else \
	  rm -f deps/server.crt deps/server.pem deps/commonName.txt; \
	  echo "NOTICE: No local HTTPS TLS credentials bundled; retired backloop.dev downloads skipped."; \
	  echo "NOTICE: Local HTTPS installation requires a separately configured trusted server certificate."; \
	fi

$(SCHEMES): deps
	xcodebuild \
	    -project ShrubSign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -jobs 4 \
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

	# Preserve regular file modes and avoid a recursive chmod on large apps.
	chmod 0755 "$(STAGE)/Payload/$@.app"
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$@.app"

	@if ls deps/* >/dev/null 2>&1; then cp deps/* "$(STAGE)/Payload/$@.app/"; fi

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
