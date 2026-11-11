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

changelog-clean:
	rm -f changelog.db changelog.json

.PHONY: backups changelog-clean format-check
