RUST_LIB = target/release/librsmatrix_ffi.a
BRIDGING_HEADER = macos/rsmatrix-ffi-Bridging.h
SWIFT_FILES = macos/saver/MatrixSaverView.swift macos/MatrixRenderer.swift
APP_SWIFT_FILES = macos/app/main.swift macos/app/MatrixView.swift macos/MatrixRenderer.swift
BUILD_DIR = build
SAVER_DIR = $(BUILD_DIR)/MatrixSaver.saver

.PHONY: all clean install-saver saver app run-app rust

all: saver

rust: $(RUST_LIB)

$(RUST_LIB):
	cargo build --release -p rsmatrix-ffi

saver: $(RUST_LIB) $(SWIFT_FILES) $(BRIDGING_HEADER)
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
		-framework CoreText \
		-Xlinker -install_name -Xlinker @rpath/MatrixSaver \
		$(SWIFT_FILES) \
		-o $(SAVER_DIR)/Contents/MacOS/MatrixSaver
	codesign --force --sign - $(SAVER_DIR)

app: $(RUST_LIB) $(APP_SWIFT_FILES) $(BRIDGING_HEADER)
	mkdir -p $(BUILD_DIR)/Matrix.app/Contents/MacOS
	cp macos/app/Info.plist $(BUILD_DIR)/Matrix.app/Contents/
	swiftc \
		-module-name MatrixApp \
		-import-objc-header $(BRIDGING_HEADER) \
		-L target/release \
		-lrsmatrix_ffi \
		-framework AppKit \
		-framework CoreText \
		-framework QuartzCore \
		$(APP_SWIFT_FILES) \
		-o $(BUILD_DIR)/Matrix.app/Contents/MacOS/MatrixApp
	codesign --force --sign - $(BUILD_DIR)/Matrix.app

run-app: app
	open $(BUILD_DIR)/Matrix.app

install-saver: saver
	cp -R $(SAVER_DIR) ~/Library/Screen\ Savers/
	@echo "Installed MatrixSaver.saver to ~/Library/Screen Savers/"
	@echo "Open System Settings > Screen Saver to select it."

clean:
	cargo clean
	rm -rf $(BUILD_DIR)
