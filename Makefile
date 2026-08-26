PREFIX  ?= $(HOME)
BIN_DIR := $(PREFIX)/bin

.PHONY: install uninstall test

install:
	@echo "==> Installiere Binaries nach $(BIN_DIR)..."
	install -d "$(BIN_DIR)"
	install -m 755 bin/shadeToggle "$(BIN_DIR)/"
	@echo "Fertig. Verknüpfe '$(BIN_DIR)/shadeToggle' in kcm_keys mit deinem Shortcut."

uninstall:
	@echo "==> Entferne Binaries aus $(BIN_DIR)..."
	rm -f "$(BIN_DIR)/shadeToggle"

test:
	@echo "Wechsle innerhalb von 2 Sekunden auf das Zielfenster..."
	@sleep 2
	@"$(BIN_DIR)/shadeToggle"
