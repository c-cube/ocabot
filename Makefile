CHANGELOG_URL = https://raw.githubusercontent.com/Octachron/ocaml-changelog-analyzer/refs/heads/main/refs/changes.json

all: build test

build:
	@dune build @install

test: build
	@dune runtest --no-buffer --force
	@echo "Tests passed."

clean:
	@dune clean

doc:
	@dune build @doc

format:
	@dune build $(DUNE_OPTS) @fmt --auto-promote

format-check:
	@dune build $(DUNE_OPTS) @fmt --display=quiet

backups:
	#@echo "doing backups of all .json files…"
	./tools/save.sh *.json

changelog.json:
	curl -fsSL '$(CHANGELOG_URL)' -o changelog.json

changelog-fetch: changelog.json

changelog-import: changelog.json
	python3 tools/import_changelog.py import

changelog-search:
	@python3 tools/import_changelog.py search $(QUERY)

changelog-clean:
	rm -f changelog.json changelog.db

.PHONY: backups changelog-fetch changelog-import changelog-search changelog-clean format-check
