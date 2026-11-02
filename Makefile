.PHONY: build test badge-test integration-test widget-build xcode-project package dmg release-package public-release-check install run docs-screenshot clean

build:
	swift build

test:
	swift run CodexUsageVerifier

badge-test:
	$${CODEX_BADGE_NODE:-node} --test Tests/codex_usage_badge_health.test.cjs
	python3 -m unittest discover -s Tests -p 'test_badge_packaging.py'

integration-test:
	swift run CodexUsageVerifier --integration

widget-build:
	swift build --product CodexUsageWidget

xcode-project:
	./Scripts/generate-project.sh

package:
	./Scripts/package.sh

dmg: package
	./Scripts/create_dmg.sh

release-package:
	./Scripts/release_package.sh

public-release-check:
	./Scripts/public_release_check.py

install:
	./Scripts/install.sh

run: package
	open "dist/Codex Monitor.app"

docs-screenshot:
	./Scripts/render-documentation-snapshot.sh

clean:
	swift package clean
	rm -rf dist
