(lang dune 3.17)
(name kom)
(generate_opam_files true)
(source (github finalclass/ocaml-kom))
(authors "Kom contributors")
(pin
 (url "git+https://github.com/finalclass/cyrograf.git#8f07d974c633054ec44196bedab5e130b454c129")
 (package (name cyrograf)))
(package
 (name kom)
 (version 0.1.0)
 (synopsis "Stateful cells and declarative message flows for OCaml")
 (depends (ocaml (= 5.4.1)) cyrograf yojson))
(package
 (name kom-sqlite)
 (version 0.1.0)
 (synopsis "SQLite execution store for Kom")
 (depends kom sqlite3))
