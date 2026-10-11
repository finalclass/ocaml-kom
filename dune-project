(lang dune 3.17)
(name kom)
(generate_opam_files true)
(source (github finalclass/ocaml-kom))
(authors "Kom contributors")
(package
 (name kom)
 (version 0.1.0)
 (synopsis "Stateful JSON cells and declarative flows for OCaml")
 (depends (ocaml (= 5.4.1)) yojson eio (eio_main :with-test) (mustache :with-test) (ezjsonm :with-test) (ppx_deriving_yojson :with-test)))
(package
 (name kom-sqlite)
 (version 0.1.0)
 (synopsis "SQLite execution store for Kom")
 (depends kom sqlite3 eio))

(package
 (name kom-runtime)
 (version 0.1.0)
 (synopsis "Persistent application host, native plugins and files for Kom")
 (depends kom kom-sqlite yojson eio eio_main sqlite3 mustache ezjsonm ppx_deriving_yojson))
