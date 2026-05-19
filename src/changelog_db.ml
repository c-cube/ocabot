(** Core changelog DB logic: schema, query parsing, search, formatting.
    No dependency on Calculon — importable from tests. *)

module DB = Sqlite3

(* ── DB helpers ──────────────────────────────────────────────────────────── *)

let check_db db rc =
  if DB.Rc.is_success rc || rc = DB.Rc.ROW then
    ()
  else
    failwith
      (Printf.sprintf "DB error: %s %s" (DB.Rc.to_string rc) (DB.errmsg db))

let exec1 db sql = DB.exec db sql |> check_db db

(* ── schema ──────────────────────────────────────────────────────────────── *)

let prepare_db (db : DB.db) =
  exec1 db
    {|CREATE TABLE IF NOT EXISTS entries (
        id           INTEGER PRIMARY KEY,
        version      TEXT NOT NULL,
        version_full TEXT NOT NULL,
        category     TEXT NOT NULL,
        text         TEXT NOT NULL,
        breaking     INTEGER NOT NULL DEFAULT 0,
        authors      TEXT NOT NULL DEFAULT '',
        prs          TEXT NOT NULL DEFAULT ''
      )|};
  exec1 db
    {|CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        version,
        category,
        text,
        authors,
        content='entries',
        content_rowid='id'
      )|};
  exec1 db
    {|CREATE TRIGGER IF NOT EXISTS entries_ai
        AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid, version, category, text, authors)
          VALUES (new.id, new.version, new.category, new.text, new.authors);
        END|};
  exec1 db
    {|CREATE TRIGGER IF NOT EXISTS entries_ad
        AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, version, category, text, authors)
          VALUES ('delete', old.id, old.version, old.category, old.text, old.authors);
        END|}

(* Insert a single entry; used by tests and the Python importer. *)
type entry = {
  version: string;
  version_full: string;
  category: string;
  text: string;
  breaking: bool;
  authors: string;
  prs: string; (** comma-separated PR numbers *)
}

let insert_entry db (e : entry) =
  let stmt =
    DB.prepare db
      {|INSERT INTO entries(version, version_full, category, text, breaking, authors, prs)
        VALUES (?,?,?,?,?,?,?)|}
  in
  DB.bind_text stmt 1 e.version |> check_db db;
  DB.bind_text stmt 2 e.version_full |> check_db db;
  DB.bind_text stmt 3 e.category |> check_db db;
  DB.bind_text stmt 4 e.text |> check_db db;
  DB.bind_int stmt 5 (if e.breaking then 1 else 0) |> check_db db;
  DB.bind_text stmt 6 e.authors |> check_db db;
  DB.bind_text stmt 7 e.prs |> check_db db;
  DB.step stmt |> check_db db;
  DB.finalize stmt |> check_db db

(* ── query parsing ───────────────────────────────────────────────────────── *)

type filters = {
  fts_query: string;
      (** free-text terms forwarded to FTS5; empty means "match all" *)
  author: string option;  (** [from:X] — substring match on authors field *)
  pr: string option;      (** [pr:N]   — exact PR number in prs field *)
  ver: string option;     (** [ver:V]  — prefix match on version field *)
}

let re_filter =
  Re.compile
    Re.(
      seq
        [
          group (alt [ str "from"; str "pr"; str "ver" ]);
          char ':';
          group (rep1 (compl [ space ]));
        ])

let parse_query raw : filters =
  let author = ref None in
  let pr = ref None in
  let ver = ref None in
  List.iter
    (fun g ->
      match Re.Group.get g 1, Re.Group.get g 2 with
      | "from", v -> author := Some v
      | "pr", v -> pr := Some v
      | "ver", v -> ver := Some v
      | _ -> ())
    (Re.all re_filter raw);
  let fts_query = Re.replace_string re_filter ~by:"" raw |> String.trim in
  { fts_query; author = !author; pr = !pr; ver = !ver }

(* ── search ──────────────────────────────────────────────────────────────── *)

type result_row = {
  version: string;
  category: string;
  breaking: bool;
  authors: string;
  prs: string;
  snippet: string; (** FTS snippet or trimmed text *)
}

let max_results = 3

let search ?(limit = max_results) (db : DB.db) (f : filters) : result_row list =
  (* Accumulate extra WHERE clauses and bound parameters in parallel. *)
  let wheres = Buffer.create 64 in
  let params = Queue.create () in
  let add_where w = Buffer.add_string wheres (" AND " ^ w) in
  let bind v = Queue.add v params in

  (* FTS match — only when there is a query term. *)
  let use_fts = f.fts_query <> "" in

  if use_fts then bind f.fts_query;

  (match f.author with
  | None -> ()
  | Some a ->
    add_where "lower(e.authors) LIKE lower('%' || ? || '%')";
    bind a);

  (match f.pr with
  | None -> ()
  | Some p ->
    (* The prs column is a comma-separated list; match the number exactly,
       handling first/last/only positions without allocating a split list. *)
    add_where
      {|(',' || e.prs || ',') LIKE ('%,' || ? || ',%')|};
    bind p);

  (match f.ver with
  | None -> ()
  | Some v ->
    add_where "e.version LIKE ? || '%'";
    bind v);

  let extra = Buffer.contents wheres in
  let sql =
    if use_fts then
      Printf.sprintf
        {|SELECT e.version, e.category, e.breaking, e.authors, e.prs,
                 snippet(entries_fts, 2, '[', ']', '…', 20)
          FROM entries_fts f
          JOIN entries e ON e.id = f.rowid
          WHERE entries_fts MATCH ? %s
          ORDER BY rank
          LIMIT %d|}
        extra limit
    else
      Printf.sprintf
        {|SELECT e.version, e.category, e.breaking, e.authors, e.prs,
                 substr(e.text, 1, 200)
          FROM entries e
          WHERE 1=1 %s
          ORDER BY e.version DESC
          LIMIT %d|}
        extra limit
  in
  let stmt = DB.prepare db sql in
  (try
     let idx = ref 1 in
     Queue.iter
       (fun v ->
         DB.bind_text stmt !idx v |> check_db db;
         incr idx)
       params;
     let rows = ref [] in
     while DB.step stmt = DB.Rc.ROW do
       rows :=
         {
           version = DB.column_text stmt 0;
           category = DB.column_text stmt 1;
           breaking = DB.column_int stmt 2 = 1;
           authors = DB.column_text stmt 3;
           prs = DB.column_text stmt 4;
           snippet = DB.column_text stmt 5;
         }
         :: !rows
     done;
     DB.finalize stmt |> check_db db;
     List.rev !rows
   with exn ->
     (try DB.finalize stmt |> ignore with _ -> ());
     raise exn)

(* ── formatting ──────────────────────────────────────────────────────────── *)

let pr_url n = Printf.sprintf "https://github.com/ocaml/ocaml/pull/%s" n

let nonempty_prs prs =
  List.filter (fun s -> s <> "") (String.split_on_char ',' prs)

(** Format one result row into 2–3 IRC lines. *)
let format_row (r : result_row) : string list =
  let flag = if r.breaking then " \x02[BREAKING]\x02" else "" in
  let header =
    Printf.sprintf "\x02[%s]\x02 %s%s" r.version (String.trim r.category) flag
  in
  let body = "  " ^ r.snippet in
  match
    ( (if r.authors <> "" then
         [ "by " ^ r.authors ]
       else
         []),
      List.map pr_url (nonempty_prs r.prs) )
  with
  | [], [] -> [ header; body ]
  | by, urls -> [ header; body; "  " ^ String.concat " | " (by @ urls) ]

(** Render the query description used in the "Top N results for" header. *)
let describe_filters (f : filters) : string =
  let parts =
    List.filter_map Fun.id
      [
        (if f.fts_query <> "" then
           Some f.fts_query
         else
           None);
        Option.map (fun a -> "from:" ^ a) f.author;
        Option.map (fun p -> "pr:" ^ p) f.pr;
        Option.map (fun v -> "ver:" ^ v) f.ver;
      ]
  in
  String.concat " " parts

(** Format a full result set into IRC lines. *)
let format_results ~(raw : string) ~(limit : int) (f : filters)
    (rows : result_row list) : string list =
  match rows with
  | [] ->
    let q =
      if raw = "" then
        "(empty query)"
      else
        raw
    in
    [ Printf.sprintf "No changelog entry found for %S." q ]
  | rows ->
    let header =
      if List.length rows >= limit then
        Printf.sprintf "Top %d results for %S:" limit (describe_filters f)
      else
        Printf.sprintf "%d result(s) for %S:" (List.length rows)
          (describe_filters f)
    in
    header :: List.concat_map format_row rows
