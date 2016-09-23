TARGETS = src/ocabot.native src/ocabotlib.cma src/ocabotlib.cmxa src/ocabotlib.cmxs

all:
	ocamlbuild -cflag -safe-string -use-ocamlfind $(TARGETS)

clean:
	ocamlbuild -clean

backups:
	@echo "doing backups of all .json files…"
	./tools/save.sh *.json

.DEFAULT_GOAL := all
.PHONY: all clean backups
