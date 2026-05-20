(** Tests for Changelog_db: query parsing, search, formatting. Uses an in-memory
    SQLite DB — no IRC server needed. *)

open Changelog_db

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let make_db () =
  let db = Sqlite3.db_open ":memory:" in
  prepare_db db;
  db

(** Seed the in-memory DB with a small fixed dataset. *)
let seed db =
  List.iter (insert_entry db)
    [
      {
        version = "5.2.0";
        version_full = "OCaml 5.2.0";
        category = "Standard library";
        text = "Add the Dynarray module to the stdlib.";
        breaking = false;
        authors = [ "Gabriel Scherer"; "Simon Cruanes" ];
        prs = "11563";
      };
      {
        version = "5.3.0";
        version_full = "OCaml 5.3.0";
        category = "Standard library";
        text = "Dynarray.blit, extends destination dynarray.";
        breaking = false;
        authors = [ "Gabriel Scherer" ];
        prs = "13197";
      };
      {
        version = "5.4.0";
        version_full = "OCaml 5.4.0";
        category = "Language features";
        text = "Added immutable arrays (iarray type, Iarray module).";
        breaking = false;
        authors = [ "Antal Spector-Zabusky"; "Olivier Nicole" ];
        prs = "13097";
      };
      {
        version = "5.4.0";
        version_full = "OCaml 5.4.0";
        category = "Standard library";
        text = "Do not raise Invalid_argument on negative List.take.";
        breaking = true;
        authors = [ "Daniel Buenzli" ];
        prs = "14124";
      };
      {
        version = "4.14.0";
        version_full = "OCaml 4.14.0";
        category = "Runtime system";
        text = "Fix potential segfault in GC compaction.";
        breaking = false;
        authors = [ "Nick Barnes" ];
        prs = "10,11";
      };
    ]

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let contains_sub haystack needle =
  let n = String.length haystack and m = String.length needle in
  let rec go i =
    i + m <= n && (String.sub haystack i m = needle || go (i + 1))
  in
  go 0

let n_results db raw = List.length (search db (parse_query raw))

(* ── parse_query tests ───────────────────────────────────────────────────────── *)

let test_parse_plain () =
  let f = parse_query "dynarray" in
  Alcotest.(check string) "fts" "dynarray" f.fts_query;
  Alcotest.(check (option string)) "no author" None f.author;
  Alcotest.(check (option string)) "no pr" None f.pr;
  Alcotest.(check (option string)) "no ver" None f.ver

let test_parse_from () =
  let f = parse_query "dynarray from:gabriel" in
  Alcotest.(check string) "fts" "dynarray" f.fts_query;
  Alcotest.(check (option string)) "author" (Some "gabriel") f.author

let test_parse_pr () =
  let f = parse_query "pr:13197" in
  Alcotest.(check string) "fts empty" "" f.fts_query;
  Alcotest.(check (option string)) "pr" (Some "13197") f.pr

let test_parse_ver () =
  let f = parse_query "iarray ver:5.4" in
  Alcotest.(check string) "fts" "iarray" f.fts_query;
  Alcotest.(check (option string)) "ver" (Some "5.4") f.ver

let test_parse_all_filters () =
  let f = parse_query "dynarray from:gabriel pr:11563 ver:5.2" in
  Alcotest.(check string) "fts" "dynarray" f.fts_query;
  Alcotest.(check (option string)) "author" (Some "gabriel") f.author;
  Alcotest.(check (option string)) "pr" (Some "11563") f.pr;
  Alcotest.(check (option string)) "ver" (Some "5.2") f.ver

(* ── search tests ─────────────────────────────────────────────────────────────── *)

let test_search_fts db () =
  let rows = search db (parse_query "dynarray") in
  Alcotest.(check bool) "found >= 2 dynarray rows" true (List.length rows >= 2);
  List.iter
    (fun r ->
      Alcotest.(check bool)
        "version starts with 5" true
        (String.length r.version >= 1 && r.version.[0] = '5'))
    rows

let test_search_from db () =
  let rows = search db (parse_query "dynarray from:gabriel") in
  Alcotest.(check bool) "at least 1" true (List.length rows >= 1);
  (* verify via authors table *)
  List.iter
    (fun r ->
      let names = fetch_authors db r.id in
      Alcotest.(check bool)
        "gabriel in authors" true
        (List.exists
           (fun n -> contains_sub (String.lowercase_ascii n) "gabriel")
           names))
    rows

let test_search_pr_single db () =
  let rows = search db (parse_query "pr:13197") in
  Alcotest.(check int) "exactly 1" 1 (List.length rows);
  Alcotest.(check string) "version" "5.3.0" (List.hd rows).version

let test_search_pr_multivalue db () =
  (* prs="10,11": pr:10 and pr:11 match; pr:1 must not (exact boundary) *)
  Alcotest.(check int) "pr:10 => 1" 1 (n_results db "pr:10");
  Alcotest.(check int) "pr:11 => 1" 1 (n_results db "pr:11");
  Alcotest.(check int) "pr:1 => 0" 0 (n_results db "pr:1")

let test_search_ver db () =
  let rows = search db (parse_query "ver:5.4") in
  Alcotest.(check int) "2 entries at 5.4" 2 (List.length rows);
  List.iter
    (fun r ->
      Alcotest.(check bool)
        "starts with 5.4" true
        (contains_sub r.version "5.4"))
    rows

let test_search_no_results db () =
  Alcotest.(check int) "no results" 0 (n_results db "xyzzy_nonexistent_token")

let test_search_breaking db () =
  let rows = search db (parse_query "ver:5.4") in
  let breaking = List.filter (fun r -> r.breaking) rows in
  Alcotest.(check int) "one breaking entry at 5.4" 1 (List.length breaking)

let test_search_fts_and_ver db () =
  let rows = search db (parse_query "dynarray ver:5.3") in
  Alcotest.(check int) "1 match" 1 (List.length rows);
  Alcotest.(check string) "version" "5.3.0" (List.hd rows).version

(* ── formatting tests ─────────────────────────────────────────────────────────── *)

let test_format_no_results db () =
  let f = parse_query "xyzzy" in
  let lines = format_results ~raw:"xyzzy" ~limit:2 f db [] in
  Alcotest.(check int) "one line" 1 (List.length lines);
  Alcotest.(check bool)
    "contains 'No changelog'" true
    (contains_sub (List.hd lines) "No changelog")

let test_format_row_single_line db () =
  (* row with breaking flag: result must be a single line *)
  let rows = search db (parse_query "negative") in
  Alcotest.(check bool) "found" true (rows <> []);
  let line = format_row db (List.hd rows) in
  Alcotest.(check bool) "single string, no newline" true
    (not (contains_sub line "\n"));
  Alcotest.(check bool) "has BREAKING" true (contains_sub line "BREAKING")

let test_format_row_has_pr_url db () =
  let rows = search db (parse_query "pr:13197") in
  Alcotest.(check bool) "found" true (rows <> []);
  let line = format_row db (List.hd rows) in
  Alcotest.(check bool) "contains pull URL" true
    (contains_sub line "github.com/ocaml/ocaml/pull/13197")

let test_format_row_has_author db () =
  let rows = search db (parse_query "pr:13197") in
  let line = format_row db (List.hd rows) in
  Alcotest.(check bool) "contains 'by'" true (contains_sub line " by ")

let test_format_row_fits_irc db () =
  (* every formatted line must fit within irc_max *)
  let rows = search ~limit:10 db (parse_query "") in
  List.iter
    (fun r ->
      let line = format_row db r in
      Alcotest.(check bool)
        (Printf.sprintf "fits irc_max: %d chars" (String.length line))
        true
        (String.length line <= irc_max))
    rows

let test_format_results_max2 db () =
  (* should return header + at most max_results lines *)
  let f = parse_query "" in
  let rows = search ~limit:max_results db f in
  let lines = format_results ~raw:"" ~limit:max_results f db rows in
  (* 1 header + up to max_results result lines *)
  Alcotest.(check bool) "<= 1 + max_results lines" true
    (List.length lines <= 1 + max_results)

let test_describe_filters () =
  let f = parse_query "dynarray from:gabriel ver:5.2" in
  let s = describe_filters f in
  Alcotest.(check bool) "non-empty" true (s <> "");
  Alcotest.(check bool) "has from:gabriel" true (contains_sub s "from:gabriel");
  Alcotest.(check bool) "has ver:5.2" true (contains_sub s "ver:5.2");
  Alcotest.(check bool) "has dynarray" true (contains_sub s "dynarray")

(* ── suite ────────────────────────────────────────────────────────────────────── *)

let () =
  let db = make_db () in
  seed db;
  Alcotest.run "changelog"
    [
      ( "parse_query",
        [
          Alcotest.test_case "plain term" `Quick test_parse_plain;
          Alcotest.test_case "from: filter" `Quick test_parse_from;
          Alcotest.test_case "pr: filter" `Quick test_parse_pr;
          Alcotest.test_case "ver: filter" `Quick test_parse_ver;
          Alcotest.test_case "all filters" `Quick test_parse_all_filters;
        ] );
      ( "search",
        [
          Alcotest.test_case "fts" `Quick (test_search_fts db);
          Alcotest.test_case "from:" `Quick (test_search_from db);
          Alcotest.test_case "pr: single" `Quick (test_search_pr_single db);
          Alcotest.test_case "pr: multi-value" `Quick
            (test_search_pr_multivalue db);
          Alcotest.test_case "ver:" `Quick (test_search_ver db);
          Alcotest.test_case "no results" `Quick (test_search_no_results db);
          Alcotest.test_case "breaking flag" `Quick (test_search_breaking db);
          Alcotest.test_case "fts + ver:" `Quick (test_search_fts_and_ver db);
        ] );
      ( "format",
        [
          Alcotest.test_case "no results msg" `Quick (test_format_no_results db);
          Alcotest.test_case "single line" `Quick (test_format_row_single_line db);
          Alcotest.test_case "pr url in line" `Quick (test_format_row_has_pr_url db);
          Alcotest.test_case "author in line" `Quick (test_format_row_has_author db);
          Alcotest.test_case "fits irc_max" `Quick (test_format_row_fits_irc db);
          Alcotest.test_case "max 2 results" `Quick (test_format_results_max2 db);
          Alcotest.test_case "describe_filters" `Quick test_describe_filters;
        ] );
    ]
