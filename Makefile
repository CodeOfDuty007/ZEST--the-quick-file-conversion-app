.PHONY: bootstrap test app run launch install cli project cert clean

DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Zest.app

# With the local "Zest Dev" identity (make cert) permission grants survive rebuilds.
# Everyone else keeps the ad-hoc signature.
# Xcode only finds identities in the keychain search list, which we leave alone, so the
# build is ad-hoc signed and then re-signed by scripts/resign-dev.sh.
RESIGN := ./scripts/resign-dev.sh $(APP)

XCB := xcodebuild -project Zest.xcodeproj -scheme Zest -configuration Debug -derivedDataPath $(DERIVED)

bootstrap:
	./scripts/bootstrap.sh

project:
	xcodegen generate

cert:
	./scripts/make-dev-cert.sh

test: project
	$(XCB) test

app: project
	$(XCB) build
	@$(RESIGN)

# Relaunch the last build without rebuilding (rebuilding can drop permission grants).
launch:
	-pkill -x Zest
	open $(APP)

run: app launch

cli:
	cd Packages/ZestCLI && swift build -c release

clean:
	rm -rf build Zest.xcodeproj Packages/*/.build

# Copy the build to ~/Applications so it is easy to find in file pickers and Launchpad.
install: app
	-pkill -x Zest
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/Zest.app
	ditto $(APP) $(HOME)/Applications/Zest.app
	open $(HOME)/Applications/Zest.app
