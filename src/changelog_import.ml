(** Fetch the OCaml changelog JSON and import it into [changelog.db].

    Try to avoid refetching the whole thing by getting a 304 if we can. *)

module DB = Sqlite3

let url =
  "https://raw.githubusercontent.com/Octachron/ocaml-changelog-analyzer/refs/heads/main/refs/changes.json"

(* ── version normalization ──────────────────────────────────────────────── *)

let re_version =
  Re.compile
    Re.(
      seq
        [ rep1 digit; char '.'; rep1 digit; opt (seq [ char '.'; rep1 digit ]) ])

let normalize_version v =
  if CCString.prefix ~pre:"working" (String.lowercase_ascii v) then
    "working"
  else (
    match Re.exec_opt re_version v with
    | Some g -> Re.Group.get g 0
    | None -> v
  )

(* ── json parsing ───────────────────────────────────────────────────────── *)

let strip_colon s =
  let s = String.trim s in
  match String.rindex_opt s ':' with
  | Some i -> String.sub s 0 i
  | None -> s

let entry_of_json version_full category (e : Yojson.Basic.t) =
  let open Yojson.Basic.Util in
  let version = normalize_version version_full in
  let category = strip_colon (String.trim category) in
  match member "text" e with
  | `String text ->
    let text = String.trim text in
    let breaking =
      match member "breaking change" e with
      | `Bool false | `Null -> false
      | _ -> true
    in
    let prs =
      match member "references" e with
      | `List l ->
        String.concat ","
          (List.filter_map
             (function
               | `Int n -> Some (string_of_int n)
               | _ -> None)
             l)
      | _ -> ""
    in
    let authors =
      match member "authors" e with
      | `List l ->
        List.filter_map
          (function
            | `List names ->
              Some
                (String.concat " "
                   (List.filter_map
                      (function
                        | `String s -> Some s
                        | _ -> None)
                      names))
            | _ -> None)
          l
      | _ -> []
    in
    Some
      {
        Changelog_db.version;
        version_full;
        category;
        text;
        breaking;
        authors;
        prs;
      }
  | _ -> None

let parse (json : Yojson.Basic.t) : Changelog_db.entry list =
  let entries = ref [] in
  let versions =
    match json with
    | `Assoc l -> l
    | _ -> []
  in
  List.iter
    (fun (version_full, categories) ->
      let categories =
        match categories with
        | `Assoc l -> l
        | _ -> []
      in
      List.iter
        (fun (category, es) ->
          let es =
            match es with
            | `List l -> l
            | _ -> []
          in
          List.iter
            (fun e ->
              match entry_of_json version_full category e with
              | Some entry -> entries := entry :: !entries
              | None -> ())
            es)
        categories)
    versions;
  List.rev !entries

(* ── fetch ────────────────────────────────────────────────────────────────── *)

type fetch_result =
  | Not_modified
  | Fetched of {
      body: string;
      etag: string option;
    }

let fetch ?etag () : (fetch_result, string) result =
  let headers =
    match etag with
    | Some e -> [ "If-None-Match", e ]
    | None -> []
  in
  match Ezcurl.http ~headers ~url ~meth:GET () with
  | Ok resp ->
    (match resp.code with
    | 200 ->
      let etag =
        List.find_map
          (fun (k, v) ->
            if String.lowercase_ascii k = "etag" then
              Some v
            else
              None)
          resp.headers
      in
      Ok (Fetched { body = resp.body; etag })
    | 304 -> Ok Not_modified
    | code -> Error (Printf.sprintf "HTTP %d" code))
  | Error (_, msg) -> Error (Printf.sprintf "curl error: %s" msg)

(* ── import ──────────────────────────────────────────────────────────────── *)

let import ?sha256 ?etag db (entries : Changelog_db.entry list) : unit =
  let exec sql = DB.exec db sql |> Changelog_db.check_db db in
  exec "BEGIN";
  try
    exec {|DELETE FROM entry_authors|};
    exec {|DELETE FROM entries|};
    exec {|DELETE FROM authors|};
    List.iter (Changelog_db.insert_entry db) entries;
    Option.iter (Changelog_db.meta_set db "sha256") sha256;
    Option.iter (Changelog_db.meta_set db "etag") etag;
    exec "COMMIT"
  with exn ->
    (try DB.exec db "ROLLBACK" |> ignore with _ -> ());
    raise exn

(* ── refresh ─────────────────────────────────────────────────────────────── *)

let close_db db =
  while not (DB.db_close db) do
    ()
  done

let refresh ~db_file () =
  try
    let db = DB.db_open db_file in
    Changelog_db.prepare_db db;
    DB.busy_timeout db 5_000;
    let stored_hash = Changelog_db.meta_get db "sha256" in
    let stored_etag = Changelog_db.meta_get db "etag" in
    match fetch ?etag:stored_etag () with
    | Error msg ->
      close_db db;
      Logs.err (fun k -> k "changelog: fetch failed: %s" msg)
    | Ok Not_modified ->
      close_db db;
      Logs.info (fun k -> k "changelog unchanged (HTTP 304)")
    | Ok (Fetched { body; etag }) ->
      let sha256 = Sha256.to_hex (Sha256.string body) in
      if Some sha256 = stored_hash then (
        (match etag, stored_etag with
        | Some e, Some s when e <> s -> Changelog_db.meta_set db "etag" e
        | _ -> ());
        close_db db;
        Logs.info (fun k -> k "changelog body unchanged, skipping import")
      ) else (
        let entries = parse (Yojson.Basic.from_string body) in
        import ~sha256 ?etag db entries;
        close_db db;
        Logs.info (fun k ->
            k "changelog: imported %d entries" (List.length entries))
      )
  with exn ->
    Logs.err (fun k ->
        k "changelog: refresh failed: %s" (Printexc.to_string exn))
