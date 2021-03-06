#!/usr/bin/env ocaml

#use "topfind";;
#require "lwt.unix";;
#require "irc-client.lwt";;
#require "str";;
#require "yojson";;
#require "containers";;
#directory "_build/src";;
#load "ocaobtlib.cma";;

let s = CCIO.with_in "old_dump" CCIO.read_lines_l;;
let l = CCList.filter_map Factoids.parse_op s;;
let fs = List.fold_left (fun acc (Factoids.Set f) -> Factoids.append f acc) Factoids.empty l;;
Printf.printf "%d records\n" (Prelude.StrMap.cardinal fs);;
Factoids.write_file ~file:"factoids.json" fs |> Lwt_main.run;;

