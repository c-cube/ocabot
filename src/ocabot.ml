module C = Calculon

let db_file = "changelog.db"

let all_ : C.Plugin.t list =
  [
    C.Plugin_social.plugin;
    C.Plugin_factoids.plugin;
    C.Plugin_state.plugin;
    C.Plugin_history.plugin ~n:100 ();
    Hello.plugin;
    Plugin_changelog.plugin ~db_file;
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
    check_cert = false;
    channels = [ "#ocaml" ];
    tls = true;
    sasl = true;
  }

let refresh_hours () =
  match Sys.getenv_opt "CHANGLEOG_REFRESH_HOURS" with
  | None -> 24
  | Some s ->
    (match int_of_string_opt (String.trim s) with
    | Some h when h > 0 -> h
    | _ ->
      Logs.warn (fun k -> k "invalid CHANGLEOG_REFRESH_HOURS %S, using 24" s);
      24)

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
    Eio.Fiber.fork ~sw (fun () ->
        let hours = float_of_int (refresh_hours ()) *. 3600. in
        let refresh () =
          Eio_unix.run_in_systhread (Changelog_import.refresh ~db_file)
        in
        refresh ();
        while true do
          Eio.Time.sleep clock hours;
          refresh ()
        done);
    C.Run_main.main ~sw ~net ~clock config all_
  with
  | Arg.Help msg -> print_endline msg
  | Arg.Bad msg ->
    prerr_endline msg;
    exit 1
