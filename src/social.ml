open Prelude
open Containers
open Lwt.Infix

module J = Yojson.Basic.Util
type json = Yojson.Basic.json

type to_tell = {
  from: string;
  on_channel: string;
  msg: string;
}

(* Data for contacts *)
type contact = {
  last_seen: float;
  to_tell: to_tell list;
}

exception Bad_json

let contact_of_json (json: json): contact option =
  let member k =
    match J.member k json with
    | `Null -> raise Bad_json
    | v -> v in
  try
    { last_seen = member "lastSeen" |> J.to_float;
      to_tell =
        member "to_tell"
        |> J.convert_each (fun j ->
          match J.convert_each J.to_string j with
          | [from; on_channel; msg] -> {from; on_channel; msg}
          | _ -> raise Bad_json);
    } |> some
  with Bad_json | J.Type_error (_, _) -> None

let json_of_contact (c: contact): json =
  `Assoc [
    "lastSeen", `Float c.last_seen;
    "to_tell", `List (
      List.map (fun {from; on_channel; msg} ->
        `List [`String from; `String on_channel; `String msg]
      ) c.to_tell
    );
  ]

(* Contacts db *)

type t = contact StrMap.t

(* TODO: move to config *)
let db_filename = "socialdb.json"

let read_db (): t =
  match Yojson.Basic.from_file db_filename with
  | `Assoc l ->
    List.to_seq l
    |> Sequence.filter_map (fun (k, j) ->
      Option.(contact_of_json j >>= fun c -> Some (k, c)))
    |> StrMap.of_seq
  | exception (Sys_error _) -> StrMap.empty
  | _ -> StrMap.empty

let write_db (db: t) =
  let json = `Assoc (
    StrMap.to_seq db
    |> Sequence.map (fun (k, c) -> (k, json_of_contact c))
    |> List.of_seq
  ) in
  Yojson.Basic.to_file db_filename json

type state = t ref

let is_contact state nick = StrMap.mem nick !state

let set_data state ?(force_sync = true) nick contact =
  state := StrMap.add nick contact !state;
  if force_sync then write_db !state

let sync state = write_db !state

let new_contact state nick =
  if not (is_contact state nick) then
    set_data state nick {
      last_seen = Unix.time ();
      to_tell = [];
    }

let data state nick =
  if not @@ is_contact state nick then new_contact state nick;
  StrMap.find nick !state

(* plugin *)

(* Write the db to the disk periodically.

   We do not update the on-disk db each time lastSeen is updated (i.e. each time
   someone talks), as it's not a big deal if we lose some data about lastSeen in
   case of a crash.
*)
let save_thread state =
  let rec loop () =
    Lwt_unix.sleep 30. >>= fun () ->
    sync state; loop ()
  in
  Lwt.async loop

let cmd_tell state =
  Command.make
    ~descr:"ask the bot to transmit a message to someone absent"
    ~prio:10 ~name:"tell"
    (fun (module C:Core.S) msg ->
       match Command.match_prefix1 ~prefix:"tell" msg with
       | None -> Command.Cmd_skip
       | Some s ->
         let nick = msg.Core.nick in
         let target = Core.reply_to msg in
         try
           let dest, msg =
             let a = Str.bounded_split (Str.regexp " ") (String.trim s) 2 in
             (List.hd a, List.hd @@ List.tl a) in
           set_data state dest
             {(data state dest) with
                to_tell =
                  {from=nick; on_channel=target; msg}
                  :: (data state dest).to_tell};
           ;
           Command.Cmd_match (C.talk ~target Talk.Ack)
         with e ->
           Command.Cmd_fail ("tell: " ^ Printexc.to_string e)
    )

(* callback to update state, notify users of their messages, etc. *)
let on_message (module C:Core.S) state msg =
  let module Msg = Irc_message in
  let nick =
    match msg.Msg.command with
    | Msg.JOIN (_, _) | Msg.PRIVMSG (_, _) ->
      some @@ get_nick @@ Option.get_exn msg.Msg.prefix
    | Msg.NICK newnick ->
      Some newnick
    | _ -> None
  in
  match nick with
  | None -> Lwt.return ()
  | Some nick ->
    let contact = data state nick in
    let to_tell = contact.to_tell |> List.rev in
    if to_tell <> [] then set_data state nick {contact with to_tell = []};
    Lwt_list.iter_s (fun {from=author; on_channel; msg=m} ->
      C.send_notice ~target:on_channel
        ~message:(Printf.sprintf "%s: (from %s): %s" nick author m))
      to_tell

let plugin =
  let init ((module C:Core.S) as core) _conf =
    let state = ref (read_db ()) in
    (* Update lastSeen *)
    Signal.on' C.privmsg
      (fun msg ->
         set_data state ~force_sync:false msg.Core.nick
           {(data state msg.Core.nick) with last_seen = Unix.time ()};
         Lwt.return ());
    (* notify users *)
    Signal.on' C.messages (on_message core state);
    (* periodic save *)
    save_thread state;
    Lwt.return state
  and stop state =
    write_db !state |> Lwt.return
  and commands state =
    [ cmd_tell state;
    ]
  in
  Plugin.stateful ~init ~stop commands

