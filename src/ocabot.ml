
module C = Calculon

let all_ : C.Plugin.t list = [
  C.Plugin_social.plugin;
  C.Plugin_factoids.plugin;
  C.Plugin_state.plugin;
  C.Plugin_history.plugin ~n:100 ();
  Hello.plugin;
]

let config = {
  C.Config.default with
  C.Config.
  server = "irc.freenode.net";
  port = 7000;
  username = "ocabot";
  realname = "ocabot";
  nick = "ocabot";
  channel = "#ocaml";
}

let () =
  try
    (* update with CLI parameters *)
    let config = C.Config.parse config Sys.argv in
    C.Run_main.main config all_ |> Lwt_main.run
  with
    | Arg.Help msg -> print_endline msg
    | Arg.Bad msg -> prerr_endline msg; exit 1

