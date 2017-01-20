
open Calculon

let cmd_hello : Command.t =
  Command.make_simple
    ~descr:"politeness core interface" ~prefix:"hello" ~prio:10
    (fun (input_msg:Core.privmsg) _ ->
       let who = input_msg.Core.nick in
       Lwt.return (Some ("hello " ^ who))
    )

let plugin = Plugin.of_cmd cmd_hello
