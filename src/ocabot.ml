module C = Calculon

let all_ : C.Plugin.t list =
  [
    C.Plugin_social.plugin;
    C.Plugin_factoids.plugin;
    C.Plugin_state.plugin;
    C.Plugin_history.plugin ~n:100 ();
    Hello.plugin;
    Plugin_changelog.plugin;
  ]

let config =
  {
    C.Config.default with
    C.Config.log_level = Logs.Info;
    server = "irc.libera.chat";
    port = 6697;
    username = "ocabot";
    realname = "ocabot";
    nick = "ocabot";
    channels = [ "#ocaml" ];
    tls = true;
    sasl = true;
  }

let () =
  Logs.set_reporter (Logs.format_reporter ());
  try
    let config = C.Config.parse config Sys.argv in
    Logs.set_level ~all:true (Some config.C.Config.log_level);
    Logs.info (fun k -> k "start ocabot");
    Eio_posix.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    C.Run_main.main ~sw ~net ~clock config all_
  with
  | Arg.Help msg -> print_endline msg
  | Arg.Bad msg ->
    prerr_endline msg;
    exit 1
