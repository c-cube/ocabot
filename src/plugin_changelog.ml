(** Plugin: search OCaml changelog via FTS5.

    Syntax: [!change <query> [from:<author>] [pr:<number>] [ver:<version>]]

    The <query> part is passed to FTS5; filters are exact-match post-filters. *)

open Calculon
open Db_utils

let db_file = "changelog.db"

(* ── schema ──────────────────────────────────────────────────────────────── *)

let prepare_db (db : DB.db) =
  DB.exec db
    {|CREATE TABLE IF NOT EXISTS entries (
        id           INTEGER PRIMARY KEY,
        version      TEXT NOT NULL,
        version_full TEXT NOT NULL,
        category     TEXT NOT NULL,
        text         TEXT NOT NULL,
        breaking     INTEGER NOT NULL DEFAULT 0,
        authors      TEXT,
        prs          TEXT
      );|}
  |> check_db_ db;
  DB.exec db
    {|CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        version,
        category,
        text,
        authors,
        content='entries',
        content_rowid='id'
      );|}
  |> check_db_ db;
  (* triggers are IF NOT EXISTS-safe via naming *)
  DB.exec db
    {|CREATE TRIGGER IF NOT EXISTS entries_ai
        AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid, version, category, text, authors)
          VALUES (new.id, new.version, new.category, new.text, new.authors);
        END;|}
  |> check_db_ db;
  DB.exec db
    {|CREATE TRIGGER IF NOT EXISTS entries_ad
        AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, version, category, text, authors)
          VALUES ('delete', old.id, old.version, old.category, old.text, old.authors);
        END;|}
  |> check_db_ db

(* ── query parsing ───────────────────────────────────────────────────────── *)

type filters = {
  fts_query: string; (** remaining terms for FTS5 *)
  author: string option; (** from:gabriel → match authors *)
  pr: string option; (** pr:1234 → exact match in prs field *)
  ver: string option; (** ver:5.2 → prefix match on version *)
}

let re_filter =
  Re.compile
    Re.(seq
          [
            group (alt [ str "from"; str "pr"; str "ver" ]);
            char ':';
            group (rep1 (compl [ space ]));
          ])

let parse_query raw : filters =
  let matches = Re.all re_filter raw in
  let author = ref None in
  let pr = ref None in
  let ver = ref None in
  List.iter
    (fun g ->
      let key = Re.Group.get g 1 in
      let value = Re.Group.get g 2 in
      match key with
      | "from" -> author := Some value
      | "pr" -> pr := Some value
      | "ver" -> ver := Some value
      | _ -> ())
    matches;
  (* strip all filter tokens from the FTS query *)
  let fts_query = Re.replace_string re_filter ~by:"" raw |> String.trim in
  { fts_query; author = !author; pr = !pr; ver = !ver }

(* ── search ──────────────────────────────────────────────────────────────── *)

type result_row = {
  version: string;
  category: string;
  text: string;
  breaking: bool;
  authors: string;
  prs: string;
  snippet: string;
}

let max_results = 3

(* Trim text to at most [n] chars, adding ellipsis. *)
let trim_text n s =
  if String.length s <= n then
    s
  else
    String.sub s 0 n ^ "…"

let search (db : DB.db) (filters : filters) : result_row list =
  (* Build SQL: always join entries + FTS; add WHERE clauses for filters. *)
  let extra_wheres = Buffer.create 32 in
  let add w = Buffer.add_string extra_wheres (" AND " ^ w) in
  (match filters.author with
  | None -> ()
  | Some _ -> add "lower(e.authors) LIKE lower('%' || ? || '%')");
  (match filters.pr with
  | None -> ()
  | Some _ ->
    (* prs is a comma-separated list of numbers; look for the exact number *)
    add
      "(',' || e.prs || ',' LIKE '%,' || ? || ',%'
       OR e.prs = ? OR e.prs LIKE ? || ',%' OR e.prs LIKE '%,' || ?)");
  (match filters.ver with
  | None -> ()
  | Some _ -> add "e.version LIKE ? || '%'");
  let base_sql =
    if filters.fts_query = "" then
      (* no FTS term: full scan with filters only *)
      Printf.sprintf
        {|SELECT e.version, e.category, e.text, e.breaking, e.authors, e.prs,
                 e.text AS snip
          FROM entries e
          WHERE 1=1 %s
          ORDER BY e.version DESC
          LIMIT %d|}
        (Buffer.contents extra_wheres)
        max_results
    else
      Printf.sprintf
        {|SELECT e.version, e.category, e.text, e.breaking, e.authors, e.prs,
                 snippet(entries_fts, 2, '[', ']', '…', 20) AS snip
          FROM entries_fts f
          JOIN entries e ON e.id = f.rowid
          WHERE entries_fts MATCH ? %s
          ORDER BY rank
          LIMIT %d|}
        (Buffer.contents extra_wheres)
        max_results
  in
  let stmt = DB.prepare db base_sql in
  (try
     let idx = ref 1 in
     let bind_text v =
       DB.bind_text stmt !idx v |> check_db_ db;
       incr idx
     in
     if filters.fts_query <> "" then bind_text filters.fts_query;
     (match filters.author with
     | None -> ()
     | Some a -> bind_text a);
     (match filters.pr with
     | None -> ()
     | Some p ->
       bind_text p;
       bind_text p;
       bind_text p;
       bind_text p);
     (match filters.ver with
     | None -> ()
     | Some v -> bind_text v);
     let rows = ref [] in
     let rc = ref (DB.step stmt) in
     while !rc = DB.Rc.ROW do
       let version = DB.column_text stmt 0 in
       let category = DB.column_text stmt 1 in
       let text = DB.column_text stmt 2 in
       let breaking = DB.column_int stmt 3 = 1 in
       let authors = DB.column_text stmt 4 in
       let prs = DB.column_text stmt 5 in
       let snippet = DB.column_text stmt 6 in
       rows :=
         { version; category; text; breaking; authors; prs; snippet } :: !rows;
       rc := DB.step stmt
     done;
     DB.finalize stmt |> check_db_ db;
     List.rev !rows
   with e ->
     (try DB.finalize stmt |> ignore with _ -> ());
     raise e)

(* ── formatting ──────────────────────────────────────────────────────────── *)

let pr_url n = Printf.sprintf "https://github.com/ocaml/ocaml/pull/%s" n

let format_row (r : result_row) : string list =
  let flag = if r.breaking then " \x02[BREAKING]\x02" else "" in
  let header =
    Printf.sprintf "\x02[%s]\x02 %s%s" r.version
      (String.trim r.category)
      flag
  in
  let body = trim_text 200 r.snippet in
  let meta =
    let parts = ref [] in
    if r.authors <> "" then parts := ("by " ^ r.authors) :: !parts;
    (match
       List.filter (fun s -> s <> "") (String.split_on_char ',' r.prs)
     with
     | [] -> ()
     | ns -> parts := String.concat " " (List.map pr_url ns) :: !parts);
    String.concat " | " (List.rev !parts)
  in
  let lines = [ header; "  " ^ body ] in
  if meta <> "" then
    lines @ [ "  " ^ meta ]
  else
    lines

let format_results (rows : result_row list) (filters : filters) (raw : string)
    : string list =
  match rows with
  | [] ->
    [
      Printf.sprintf "No changelog entry found for %S."
        (if raw = "" then
           "(empty query)"
         else
           raw);
    ]
  | rows ->
    let header =
      if List.length rows = max_results then
        Printf.sprintf "Top %d results for %S:" max_results
          (filters.fts_query
          ^
          (match filters.author with
          | None -> ""
          | Some a -> " from:" ^ a)
          ^
          (match filters.pr with
          | None -> ""
          | Some p -> " pr:" ^ p)
          ^
          match filters.ver with
          | None -> ""
          | Some v -> " ver:" ^ v)
      else
        Printf.sprintf "%d result(s):" (List.length rows)
    in
    header :: List.concat_map format_row rows

(* ── plugin wiring ───────────────────────────────────────────────────────── *)

let make_cmd (db : DB.db) : Command.t =
  Command.make_simple_l ~cmd:"change"
    ~descr:
      "search OCaml changelog: !change <query> [from:<author>] [pr:<num>] \
       [ver:<version>]"
    (fun _msg raw ->
      let raw = String.trim raw in
      let filters = parse_query raw in
      match search db filters with
      | exception exn ->
        [ Printf.sprintf "Error querying changelog: %s" (Printexc.to_string exn) ]
      | rows -> format_results rows filters raw)

(* Open changelog.db (read-only); create schema in case it was never imported
   so the bot starts cleanly even without the file pre-existing. *)
let open_db () : DB.db =
  let db = DB.db_open db_file in
  prepare_db db;
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
