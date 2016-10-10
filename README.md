# OCabot

IRC bot for "#OCaml" on freenode

## Build

- `opam install lwt irc-client yojson containers sequence uri cohttp lambdasoup`
- `make`
- `./ocabot.native`

## License

MIT, see `LICENSE`

## An introduction to the code

Ocabot works by registering *plugins* to the code (see `Ocabot.all_`
and the module `Plugin`). A plugin contains some hooks for startup and teardown
(mostly for storing/loading state on disk) and a set of *commands*.
Typically a command (see the module `Command`) is a rule that matches a IRC
message with some regex, and decides whether or not to fire with a reply.

For instance, the following module will reply to messages
starting with `!hello` by replying `"hello <sender>"`. This is a simple
command, as the function `Command.make_simple` indicates: it returns a `string
option` to indicate whether or not to respond to any line starting with
`!prefix`. More elaborate commands are possible using `Command.make`.

```ocaml

let cmd_hello : Command.t =
  Command.make_simple ~descr:"politeness core interface" ~prefix:"hello" ~prio:10
    (fun (input_msg:Core.privmsg) _ ->
       let who = input_msg.Core.nick in
       Lwt.return (Some ("hello " ^ who))
    )

let plugin = Plugin.of_cmd cmd_hello
```

See the existing plugins in `Factoids` and `Social` to see how to implement
stateful plugins that store their data on disk.
