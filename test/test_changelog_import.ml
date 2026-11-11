(** Tests for Changelog_import: json parsing, version normalization, and
    end-to-end import into an in-memory SQLite DB — no network needed. *)

open Changelog_db
open Changelog_import

let json =
  {|{
  "OCaml 5.4.0 (9 Oct 2025):": {
    "stdlib:": [
      {
        "text": "Add Dynarray.append.",
        "references": [13459, 13500],
        "authors": [ [ "Jane Doe", "John Smith" ] ]
      },
      {
        "text": "Remove dubious function.",
        "breaking change": true,
        "authors": [ [ "Ada L." ] ]
      }
    ],
    "runtime:": [ { "text": "Fix GC bug." } ]
  },
  "working:": {
    "stdlib:": [ { "text": "Unreleased feature." } ],
    "other": [ { "no text here": true } ]
  }
}|}

let make_db () =
  let db = Sqlite3.db_open ":memory:" in
  prepare_db db;
  db

let count db sql =
  let stmt = Sqlite3.prepare db sql in
  let (_ : Sqlite3.Rc.t) = Sqlite3.step stmt in
  let n = Sqlite3.column_int stmt 0 in
  Sqlite3.finalize stmt |> ignore;
  n

let test_normalize () =
  Alcotest.(check string)
    "release" "5.4.0"
    (normalize_version "OCaml 5.4.0 (9 Oct 2025):");
  Alcotest.(check string) "rc" "5.3.1" (normalize_version "5.3.1-rc1");
  Alcotest.(check string) "two components" "5.2" (normalize_version "OCaml 5.2");
  Alcotest.(check string) "working" "working" (normalize_version "working:");
  Alcotest.(check string)
    "working prefix" "working"
    (normalize_version "working-5.5 branch:");
  Alcotest.(check string) "no version" "hotfix" (normalize_version "hotfix")

let test_parse () =
  let entries = parse (Yojson.Basic.from_string json) in
  Alcotest.(check int) "entry count" 4 (List.length entries);
  let sorted =
    List.stable_sort
      (fun a b ->
        compare (a.version_full, a.category) (b.version_full, b.category))
      entries
  in
  let runtime = List.nth sorted 0 in
  Alcotest.(check string) "runtime version" "5.4.0" runtime.version;
  Alcotest.(check string) "category colon stripped" "runtime" runtime.category;
  Alcotest.(check string) "text" "Fix GC bug." runtime.text;
  Alcotest.(check bool) "breaking" false runtime.breaking;
  Alcotest.(check (list string)) "no authors" [] runtime.authors;
  let dyn = List.nth sorted 1 in
  Alcotest.(check string) "prs" "13459,13500" dyn.prs;
  Alcotest.(check (list string)) "authors" [ "Jane Doe John Smith" ] dyn.authors;
  let breaking = List.nth sorted 2 in
  Alcotest.(check bool) "breaking flag" true breaking.breaking;
  Alcotest.(check (list string)) "single author" [ "Ada L." ] breaking.authors;
  let working = List.nth sorted 3 in
  Alcotest.(check string) "working version" "working" working.version;
  Alcotest.(check string) "working category" "stdlib" working.category

let test_import_and_search () =
  let db = make_db () in
  import ~sha256:"hash1" db (parse (Yojson.Basic.from_string json));
  Alcotest.(check int) "entries" 4 (count db "SELECT count(*) FROM entries");
  Alcotest.(check int) "authors" 2 (count db "SELECT count(*) FROM authors");
  Alcotest.(check int)
    "author links" 2
    (count db "SELECT count(*) FROM entry_authors");
  let fts = search db (parse_query "dynarray") in
  Alcotest.(check int) "fts match" 1 (List.length fts);
  Alcotest.(check string) "fts version" "5.4.0" (List.hd fts).version;
  let breaking = search db (parse_query "dubious") in
  Alcotest.(check bool) "breaking flag" true (List.hd breaking).breaking;
  let from_author = search db (parse_query "from:Jane") in
  Alcotest.(check int) "author filter" 1 (List.length from_author);
  let by_pr = search db (parse_query "pr:13459") in
  Alcotest.(check int) "pr filter" 1 (List.length by_pr);
  let by_ver = search db (parse_query "ver:working") in
  Alcotest.(check int) "ver filter" 1 (List.length by_ver);
  Alcotest.(check (option string))
    "meta sha256" (Some "hash1") (meta_get db "sha256")

let test_reimport () =
  let db = make_db () in
  let entries = parse (Yojson.Basic.from_string json) in
  import ~sha256:"abc" ~etag:"W/\"1\"" db entries;
  import ~sha256:"abc" ~etag:"W/\"1\"" db entries;
  Alcotest.(check int)
    "entries still 4" 4
    (count db "SELECT count(*) FROM entries");
  Alcotest.(check int)
    "authors still 2" 2
    (count db "SELECT count(*) FROM authors");
  Alcotest.(check (option string))
    "sha256 stored" (Some "abc") (meta_get db "sha256");
  Alcotest.(check (option string))
    "etag stored" (Some "W/\"1\"") (meta_get db "etag")

let () =
  let open Alcotest in
  run "changelog_import"
    [
      "normalize", [ test_case "normalize_version" `Quick test_normalize ];
      "parse", [ test_case "json to entries" `Quick test_parse ];
      "import", [ test_case "import + search" `Quick test_import_and_search ];
      "reimport", [ test_case "idempotent import" `Quick test_reimport ];
    ]
