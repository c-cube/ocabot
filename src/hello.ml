
let cmd_hello : Command.t =
  Command.make_simple ~descr:"I say hello, you say goodbye" ~prefix:"hello" ~prio:10
    (fun (input_msg:Core.privmsg) _ ->
       let who = input_msg.Core.nick in
       Lwt.return (Some ("hello " ^ who))
    )

let plugin = Plugin.of_cmd cmd_hello
