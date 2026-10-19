# Convenience targets. Anything that needs Xcode runs on macOS only.
.PHONY: site project ipa check clean

site:            ## mirror dir -> dist/site.zip   (make site MIRROR=/path/to/pb_mirror)
	bash ./make_site_zip.sh "$(MIRROR)"

project:         ## generate PokeBonk.xcodeproj (needs xcodegen)
	xcodegen generate

ipa:             ## xcodegen + xcodebuild + Payload zip (unsigned, macOS)
	bash ./make_ipa.sh

check:           ## static checks that do not need Xcode
	bash -n make_ipa.sh && bash -n make_site_zip.sh
	python3 -c "import plistlib; plistlib.load(open('Resources/Info.plist','rb'))"

clean:
	rm -rf build dist PokeBonk.xcodeproj
