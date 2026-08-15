.PHONY: build test app run install icon cert cert-export dmg release clean

APP := .dist/Sidetone.app

build:
	swift build -c release

test:
	@# Built and run in two steps rather than with 'swift run', which gets killed
	@# outright on GitHub's macOS runners.
	swift build -c debug --product Verify
	"$$(swift build -c debug --show-bin-path)/Verify"

app:
	Scripts/make-app.sh release

run: app
	open $(APP)

install: app
	@pkill -x Sidetone 2>/dev/null; true
	rm -rf /Applications/Sidetone.app
	cp -R $(APP) /Applications/Sidetone.app
	@# The single instance guard rejects a launch while the old process is still
	@# exiting, so wait for it to go before opening the new one.
	@for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Sidetone >/dev/null || break; sleep 0.2; done
	@open /Applications/Sidetone.app
	@echo "installed and relaunched /Applications/Sidetone.app"

icon:
	Scripts/make-icon.sh

cert:
	Scripts/make-cert.sh

cert-export:
	Scripts/make-cert.sh --export .dist/signing-identity.p12

dmg:
	Scripts/make-dmg.sh

release:
	Scripts/make-release.sh

clean:
	rm -rf .build .dist
