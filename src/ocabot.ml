
module C = Calculon

let all_ : C.Plugin.t list = [
  C.Plugin_social.plugin;
  C.Plugin_factoids.plugin;
  Hello.plugin;
]

let () =
  let conf = C.Config.of_argv () in
  C.Run_main.main conf all_ |> Lwt_main.run

