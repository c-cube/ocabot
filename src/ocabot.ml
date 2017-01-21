
module C = Calculon

let all_ : C.Plugin.t list = [
  C.Plugin_social.plugin;
  C.Plugin_factoids.plugin;
  Hello.plugin;
]

let config = {
  C.Config.
  server = "irc.freenode.net";
  port = 7000;
  username = "ocabot";
  realname = "ocabot";
  nick = "ocabot";
  channel = "#ocaml";
  factoids_file = "factoids.json";
}

let () =
  (* update with CLI parameters *)
  let config = C.Config.parse config Sys.argv in
  C.Run_main.main config all_ |> Lwt_main.run

