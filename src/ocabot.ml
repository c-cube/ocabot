
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
  log_level = Logs.Info;
  server = "irc.libera.chat";
  port = 6697;
  username = "ocabot";
  realname = "ocabot";
  nick = "ocabot";
  channel = "#ocaml";
  tls = true;
  sasl = true;
}

let () =
  Logs.set_reporter (Logs.format_reporter ());
  try
    (* update with CLI parameters *)
    let config = C.Config.parse config Sys.argv in
    Logs.set_level ~all:true (Some config.C.Config.log_level);
    Logs.info (fun k->k"start ocabot");
    C.Run_main.main config all_ |> Lwt_main.run
  with
    | Arg.Help msg -> print_endline msg
    | Arg.Bad msg -> prerr_endline msg; exit 1

