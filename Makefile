RUST_LIB = target/release/librsmatrix_ffi.a
SWIFT_FILES = screensaver/MatrixSaver/MatrixSaverView.swift screensaver/MatrixSaver/MatrixRenderer.swift
BRIDGING_HEADER = screensaver/MatrixSaver/rsmatrix-ffi-Bridging.h
BUILD_DIR = build
SAVER_DIR = $(BUILD_DIR)/MatrixSaver.saver

.PHONY: all clean install saver rust

all: saver

rust: $(RUST_LIB)

$(RUST_LIB):
	cargo build --release -p rsmatrix-ffi

saver: $(RUST_LIB) $(SWIFT_FILES) $(BRIDGING_HEADER)
	mkdir -p $(SAVER_DIR)/Contents/MacOS
	cp screensaver/MatrixSaver/Info.plist $(SAVER_DIR)/Contents/
	swiftc \
		-emit-library \
		-module-name MatrixSaver \
		-import-objc-header $(BRIDGING_HEADER) \
		-L target/release \
		-lrsmatrix_ffi \
		-framework ScreenSaver \
		-framework AppKit \
		-Xlinker -install_name -Xlinker @rpath/MatrixSaver \
		$(SWIFT_FILES) \
		-o $(SAVER_DIR)/Contents/MacOS/MatrixSaver
	codesign --force --sign - $(SAVER_DIR)

install: saver
	cp -R $(SAVER_DIR) ~/Library/Screen\ Savers/
	@echo "Installed MatrixSaver.saver to ~/Library/Screen Savers/"
	@echo "Open System Settings > Screen Saver to select it."

clean:
	cargo clean
	rm -rf $(BUILD_DIR)
