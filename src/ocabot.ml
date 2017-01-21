
module C = Calculon

let all_ : C.Plugin.t list = [
  C.Plugin_social.plugin;
  C.Plugin_factoids.plugin;
  C.Plugin_state.plugin;
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
  (* update with CLI parameters *)
  let config = C.Config.parse config Sys.argv in
  C.Run_main.main config all_ |> Lwt_main.run

