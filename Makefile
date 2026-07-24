.PHONY: generate build test test-swift test-plugin test-release test-localization check-brand check clean open

DERIVED_DATA := .build/DerivedData

generate:
	xcodegen generate

build: generate
	xcodebuild -project LLMPulse.xcodeproj -scheme LLMPulse -configuration Debug -derivedDataPath $(DERIVED_DATA) -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build

test: test-swift test-plugin test-release test-localization

test-swift: generate
	xcodebuild -project LLMPulse.xcodeproj -scheme LLMPulse -configuration Debug -derivedDataPath $(DERIVED_DATA) -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test

test-plugin:
	python3 -m unittest discover -s Tests/Plugin -p 'test_*.py' -v

test-release:
	python3 -m unittest discover -s Tests/Release -p 'test_*.py' -v

test-localization:
	python3 -m unittest discover -s Tests/Localization -p 'test_*.py' -v

check-brand:
	bash scripts/check_brand_residuals.sh

check: check-brand test build

open: generate
	open LLMPulse.xcodeproj

clean:
	xcodebuild -project LLMPulse.xcodeproj -scheme LLMPulse -derivedDataPath $(DERIVED_DATA) clean
