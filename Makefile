
PREFIX  ?= $(HOME)
BIN_DIR := $(PREFIX)/bin

.PHONY: install uninstall test

install:
	@echo "==> Installing binaries to $(BIN_DIR)..."
	install -d "$(BIN_DIR)"
	install -m 755 bin/shadeToggle "$(BIN_DIR)/"
	@echo "Done. Now run 'kcmshell kcm_keys' to and create a keyboard shortcut for '$(BIN_DIR)/shadeToggle'"

uninstall:
	@echo "==> Removing the binary from $(BIN_DIR)..."
	rm -f "$(BIN_DIR)/shadeToggle"

test:
	@echo "Select any target window within 2 seconds..."
	@sleep 2
	@"$(BIN_DIR)/shadeToggle"
