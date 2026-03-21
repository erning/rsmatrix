RUST_LIB = target/release/librsmatrix_ffi.a
BRIDGING_HEADER = macos/rsmatrix-ffi-Bridging.h
SWIFT_FILES = macos/saver/MatrixSaverView.swift macos/MetalRenderer.swift
APP_SWIFT_FILES = macos/app/main.swift macos/app/MatrixView.swift macos/MetalRenderer.swift macos/MatrixRenderer.swift
METAL_SOURCE = macos/Shaders.metal
METAL_LIB = $(BUILD_DIR)/Matrix.app/Contents/Resources/default.metallib
SAVER_METAL_LIB = $(SAVER_DIR)/Contents/Resources/default.metallib
BUILD_DIR = build
SAVER_DIR = $(BUILD_DIR)/MatrixSaver.saver

.PHONY: all clean install-saver saver app run-app rust

all: saver

rust: $(RUST_LIB)

$(RUST_LIB):
	cargo build --release -p rsmatrix-ffi

saver: $(RUST_LIB) $(SWIFT_FILES) $(BRIDGING_HEADER) $(SAVER_METAL_LIB)
	mkdir -p $(SAVER_DIR)/Contents/MacOS
	cp macos/saver/Info.plist $(SAVER_DIR)/Contents/
	swiftc \
		-emit-library \
		-module-name MatrixSaver \
		-import-objc-header $(BRIDGING_HEADER) \
		-L target/release \
		-lrsmatrix_ffi \
		-framework ScreenSaver \
		-framework AppKit \
		-framework Metal \
		-framework MetalKit \
		-framework CoreText \
		-framework QuartzCore \
		-framework CoreImage \
		-Xlinker -install_name -Xlinker @rpath/MatrixSaver \
		$(SWIFT_FILES) \
		-o $(SAVER_DIR)/Contents/MacOS/MatrixSaver
	codesign --force --sign - $(SAVER_DIR)

$(SAVER_METAL_LIB): $(METAL_SOURCE)
	mkdir -p $(SAVER_DIR)/Contents/Resources
	xcrun metal -c $(METAL_SOURCE) -o $(BUILD_DIR)/SaverShaders.air
	xcrun metallib $(BUILD_DIR)/SaverShaders.air -o $(SAVER_METAL_LIB)
	rm -f $(BUILD_DIR)/SaverShaders.air

$(METAL_LIB): $(METAL_SOURCE)
	mkdir -p $(BUILD_DIR)/Matrix.app/Contents/Resources
	xcrun metal -c $(METAL_SOURCE) -o $(BUILD_DIR)/Shaders.air
	xcrun metallib $(BUILD_DIR)/Shaders.air -o $(METAL_LIB)
	rm -f $(BUILD_DIR)/Shaders.air

app: $(RUST_LIB) $(APP_SWIFT_FILES) $(BRIDGING_HEADER) $(METAL_LIB)
	mkdir -p $(BUILD_DIR)/Matrix.app/Contents/MacOS
	cp macos/app/Info.plist $(BUILD_DIR)/Matrix.app/Contents/
	swiftc \
		-module-name MatrixApp \
		-import-objc-header $(BRIDGING_HEADER) \
		-L target/release \
		-lrsmatrix_ffi \
		-framework AppKit \
		-framework Metal \
		-framework MetalKit \
		-framework CoreText \
		-framework QuartzCore \
		-framework CoreImage \
		$(APP_SWIFT_FILES) \
		-o $(BUILD_DIR)/Matrix.app/Contents/MacOS/MatrixApp
	codesign --force --sign - $(BUILD_DIR)/Matrix.app

run-app: app
	open $(BUILD_DIR)/Matrix.app

install-saver: saver
	killall legacyScreenSaver 2>/dev/null || true
	killall "System Settings" 2>/dev/null || true
	rm -rf ~/Library/Screen\ Savers/MatrixSaver.saver
	cp -R $(SAVER_DIR) ~/Library/Screen\ Savers/
	@echo "Installed MatrixSaver.saver to ~/Library/Screen Savers/"
	@echo "Open System Settings > Screen Saver to select it."

clean:
	cargo clean
	rm -rf $(BUILD_DIR)
