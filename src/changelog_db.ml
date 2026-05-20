(** Core changelog DB logic: schema, query parsing, search, formatting. No
    dependency on Calculon — importable from tests. *)

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
    {|CREATE TABLE IF NOT EXISTS authors (
        id   INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE
      )|};
  exec1 db {|CREATE INDEX IF NOT EXISTS authors_name ON authors(name)|};
  exec1 db
    {|CREATE TABLE IF NOT EXISTS entries (
        id           INTEGER PRIMARY KEY,
        version      TEXT NOT NULL,
        version_full TEXT NOT NULL,
        category     TEXT NOT NULL,
        text         TEXT NOT NULL,
        breaking     INTEGER NOT NULL DEFAULT 0,
        prs          TEXT NOT NULL DEFAULT ''
      )|};
  exec1 db {|CREATE INDEX IF NOT EXISTS entries_prs ON entries(prs)|};
  exec1 db
    {|CREATE TABLE IF NOT EXISTS entry_authors (
        entry_id  INTEGER NOT NULL REFERENCES entries(id),
        author_id INTEGER NOT NULL REFERENCES authors(id),
        PRIMARY KEY (entry_id, author_id)
      )|};
  exec1 db
    {|CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        version,
        category,
        text,
        content='entries',
        content_rowid='id'
      )|};
  exec1 db
    {|CREATE TRIGGER IF NOT EXISTS entries_ai
        AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid, version, category, text)
          VALUES (new.id, new.version, new.category, new.text);
        END|};
  exec1 db
    {|CREATE TRIGGER IF NOT EXISTS entries_ad
        AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, version, category, text)
          VALUES ('delete', old.id, old.version, old.category, old.text);
        END|}

(* Insert a single entry; used by tests and the Python importer. *)
type entry = {
  version: string;
  version_full: string;
  category: string;
  text: string;
  breaking: bool;
  authors: string list;  (** full names *)
  prs: string;  (** comma-separated PR numbers *)
}

let get_or_create_author db name =
  let sel = DB.prepare db {|SELECT id FROM authors WHERE name = ?|} in
  DB.bind_text sel 1 name |> check_db db;
  let id =
    if DB.step sel = DB.Rc.ROW then
      Some (DB.column_int sel 0)
    else
      None
  in
  DB.finalize sel |> check_db db;
  match id with
  | Some i -> i
  | None ->
    let ins = DB.prepare db {|INSERT INTO authors(name) VALUES (?)|} in
    DB.bind_text ins 1 name |> check_db db;
    DB.step ins |> check_db db;
    DB.finalize ins |> check_db db;
    DB.last_insert_rowid db |> Int64.to_int

let insert_entry db (e : entry) =
  let stmt =
    DB.prepare db
      {|INSERT INTO entries(version, version_full, category, text, breaking, prs)
        VALUES (?,?,?,?,?,?)|}
  in
  DB.bind_text stmt 1 e.version |> check_db db;
  DB.bind_text stmt 2 e.version_full |> check_db db;
  DB.bind_text stmt 3 e.category |> check_db db;
  DB.bind_text stmt 4 e.text |> check_db db;
  DB.bind_int stmt 5
    (if e.breaking then
       1
     else
       0)
  |> check_db db;
  DB.bind_text stmt 6 e.prs |> check_db db;
  DB.step stmt |> check_db db;
  DB.finalize stmt |> check_db db;
  let entry_id = DB.last_insert_rowid db |> Int64.to_int in
  List.iter
    (fun name ->
      let author_id = get_or_create_author db name in
      let lnk =
        DB.prepare db
          {|INSERT OR IGNORE INTO entry_authors(entry_id, author_id) VALUES (?,?)|}
      in
      DB.bind_int lnk 1 entry_id |> check_db db;
      DB.bind_int lnk 2 author_id |> check_db db;
      DB.step lnk |> check_db db;
      DB.finalize lnk |> check_db db)
    e.authors

(* ── query parsing ───────────────────────────────────────────────────────── *)

type filters = {
  fts_query: string;
      (** free-text terms forwarded to FTS5; empty means "match all" *)
  author: string option;  (** [from:X] — substring match on authors.name *)
  pr: string option;  (** [pr:N] — exact PR number in prs field *)
  ver: string option;  (** [ver:V] — prefix match on version field *)
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
  id: int;
  version: string;
  category: string;
  breaking: bool;
  prs: string;
  snippet: string;  (** FTS snippet or trimmed text *)
}

let max_results = 2

let fetch_authors db entry_id =
  let stmt =
    DB.prepare db
      {|SELECT a.name FROM authors a
        JOIN entry_authors ea ON ea.author_id = a.id
        WHERE ea.entry_id = ?
        ORDER BY a.name|}
  in
  DB.bind_int stmt 1 entry_id |> check_db db;
  let names = ref [] in
  while DB.step stmt = DB.Rc.ROW do
    names := DB.column_text stmt 0 :: !names
  done;
  DB.finalize stmt |> check_db db;
  List.rev !names

let search ?(limit = max_results) (db : DB.db) (f : filters) : result_row list =
  let wheres = Buffer.create 64 in
  let params = Queue.create () in
  let add_where w = Buffer.add_string wheres (" AND " ^ w) in
  let bind v = Queue.add v params in

  let use_fts = f.fts_query <> "" in
  if use_fts then bind f.fts_query;

  (match f.author with
  | None -> ()
  | Some a ->
    add_where
      {|EXISTS (SELECT 1 FROM entry_authors ea JOIN authors a ON a.id = ea.author_id
                WHERE ea.entry_id = e.id AND lower(a.name) LIKE lower('%' || ? || '%'))|};
    bind a);

  (match f.pr with
  | None -> ()
  | Some p ->
    add_where {|(',' || e.prs || ',') LIKE ('%,' || ? || ',%')|};
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
        {|SELECT e.id, e.version, e.category, e.breaking, e.prs,
                 snippet(entries_fts, 2, '[', ']', '…', 20)
          FROM entries_fts f
          JOIN entries e ON e.id = f.rowid
          WHERE entries_fts MATCH ? %s
          ORDER BY rank
          LIMIT %d|}
        extra limit
    else
      Printf.sprintf
        {|SELECT e.id, e.version, e.category, e.breaking, e.prs,
                 substr(e.text, 1, 200)
          FROM entries e
          WHERE 1=1 %s
          ORDER BY e.version DESC
          LIMIT %d|}
        extra limit
  in
  let stmt = DB.prepare db sql in
  try
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
          id = DB.column_int stmt 0;
          version = DB.column_text stmt 1;
          category = DB.column_text stmt 2;
          breaking = DB.column_int stmt 3 = 1;
          prs = DB.column_text stmt 4;
          snippet = DB.column_text stmt 5;
        }
        :: !rows
    done;
    DB.finalize stmt |> check_db db;
    List.rev !rows
  with exn ->
    (try DB.finalize stmt |> ignore with _ -> ());
    raise exn

(* ── formatting ──────────────────────────────────────────────────────────── *)

let pr_url n = Printf.sprintf "https://github.com/ocaml/ocaml/pull/%s" n

let nonempty_prs prs =
  List.filter (fun s -> s <> "") (String.split_on_char ',' prs)

(** IRC max message length is 512 bytes; we leave headroom for the prefix. *)
let irc_max = 400

let truncate ~max s =
  if String.length s <= max then
    s
  else
    String.sub s 0 (max - 1) ^ "\xe2\x80\xa6"  (* … *)

(** Format one result row into a single IRC line. *)
let format_row db (r : result_row) : string =
  let flag =
    if r.breaking then
      " [BREAKING]"
    else
      ""
  in
  (* build suffix: "by A, B  PR_url1 PR_url2" *)
  let authors = fetch_authors db r.id in
  let by_part =
    match authors with
    | [] -> ""
    | names -> " by " ^ String.concat ", " names
  in
  let pr_part =
    match nonempty_prs r.prs with
    | [] -> ""
    | prs -> " " ^ String.concat " " (List.map pr_url prs)
  in
  let suffix = by_part ^ pr_part in
  (* prefix: "[version] " *)
  let prefix = Printf.sprintf "[%s] " r.version in
  let prefix_len = String.length prefix in
  let suffix_len = String.length suffix in
  let flag_len = String.length flag in
  let budget = irc_max - prefix_len - flag_len - suffix_len in
  let text = truncate ~max:(max 10 budget) (String.trim r.snippet) in
  prefix ^ text ^ flag ^ suffix

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

(** Format a full result set into IRC lines (at most [max_results] entries,
    one line each, plus an optional header). *)
let format_results ~(raw : string) ~(limit : int) (f : filters)
    (db : DB.db) (rows : result_row list) : string list =
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
    header :: List.map (format_row db) rows
