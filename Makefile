# Middle-Drag Gestures - convenience targets.
#
#   make test      unit + integration tests
#   make verify    load the extension in a throwaway GNOME Shell
#   make zip       build the GNOME Extensions bundle in dist/
#   make install   redeploy everything (extension, daemon, schema, udev)
#   make clean     remove build artifacts

UUID      := middle-drag-gestures@swad
PYTHON    ?= python3

.PHONY: all test unit integration verify zip install uninstall enable disable clean

all: test

test: unit integration

unit:
	$(PYTHON) -m unittest discover -s tests -v

integration:
	$(PYTHON) tests/integration_test.py

verify:
	./scripts/verify-extension.sh

zip:
	./scripts/package-extension.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

enable:
	./scripts/enable.sh

disable:
	./scripts/disable.sh

clean:
	rm -rf dist
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -f extension/$(UUID)/schemas/gschemas.compiled
