# OCabot

IRC bot for "#OCaml" on freenode

It can be interacted with using `!`-prefixed commands. `!help` lists these.

- New factoids can be added using `!foo = bar`, which will cause `!foo` to
  answer `bar` in the future.
- `!search <pat>` and `!search_all <pat>` perform basic search among factoids.
- `!help` or `!help <command>` provide help.
- `!history` lists a few recent messages on `#ocaml`.
- `!seen <nick>` will report last time the given nickname was seen speaking on the channel.

## Build

- `opam pin add calculon https://github.com/c-cube/calculon.git`
- `make`
- `./ocabot.native`

## License

MIT, see `LICENSE`

