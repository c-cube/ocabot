(** Calculon plugin: [!change <query> [from:<author>] [pr:<num>] [ver:<ver>]]

    Searches the OCaml changelog imported into [changelog.db] via FTS5. *)

open Calculon
open Calculon.Db_utils

let db_file = "changelog.db"

let make_cmd (db : DB.db) : Command.t =
  Command.make_simple_l ~cmd:"change"
    ~descr:
      "search OCaml changelog: !change <query> [from:<author>] [pr:<num>] \
       [ver:<version>]"
    (fun _msg raw ->
      let raw = String.trim raw in
      let filters = Changelog_db.parse_query raw in
      match Changelog_db.search db filters with
      | exception exn ->
        [
          Printf.sprintf "Error querying changelog: %s"
            (Printexc.to_string exn);
        ]
      | rows ->
        Changelog_db.format_results ~raw ~limit:Changelog_db.max_results
          filters rows)

let open_db () : DB.db =
  let db = DB.db_open db_file in
  Changelog_db.prepare_db db;
  db

let plugin : Plugin.t =
  Plugin.stateful ~name:"changelog"
    ~commands:(fun db -> [ make_cmd db ])
    ~to_json:(fun _ -> None)
    ~of_json:(fun _cb _json ->
      try Ok (open_db ())
      with exn ->
        Error
          (Printf.sprintf "failed to open %s: %s" db_file
             (Printexc.to_string exn)))
    ~stop:(fun db ->
      while not (DB.db_close db) do
        ()
      done)
    ()
