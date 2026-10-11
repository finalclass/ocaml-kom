open Yojson.Safe.Util

exception Error of string

let fail message = raise (Error message)

type range =
  { prefix: string
  ; first: string option
  ; last: string option
  ; after: string option
  ; limit: int }

type backend =
  { get: string -> string option
  ; scan: range -> (string * string) list
  ; commit: (string * string option) list -> unit
  ; close: unit -> unit }

let matches range key =
  String.starts_with ~prefix:range.prefix key
  && Option.fold ~none:true ~some:(fun first -> key >= first) range.first
  && Option.fold ~none:true ~some:(fun last -> key <= last) range.last
  && Option.fold ~none:true ~some:(fun after -> key > after) range.after

let take n xs = List.filteri (fun i _ -> i < n) xs

module Strings = Map.Make (String)

let memory_backend () =
  let values = ref Strings.empty in
  { get= (fun key -> Strings.find_opt key !values)
  ; scan=
      (fun range ->
        Strings.bindings !values
        |> List.filter (fun (key, _) -> matches range key)
        |> take range.limit )
  ; commit=
      (fun writes ->
        values :=
          List.fold_left
            (fun values (key, value) ->
              match value with
              | None -> Strings.remove key values
              | Some value -> Strings.add key value values )
            !values
            writes )
  ; close= (fun () -> ()) }

let hex text =
  String.concat
    ""
    (List.init (String.length text) (fun i ->
         Printf.sprintf "%02x" (Char.code text.[i]) ) )

let component text = hex text ^ "!"

type 'a key =
  { encode: 'a -> string
  ; json: 'a -> Yojson.Safe.t
  ; decode: Yojson.Safe.t -> 'a
  ; shape: Yojson.Safe.t }

let int =
  { encode=
      (fun n ->
        Printf.sprintf "%016Lx!" (Int64.logxor (Int64.of_int n) Int64.min_int) )
  ; json= (fun n -> `Int n)
  ; decode= to_int
  ; shape= `String "int" }

let string =
  { encode= component
  ; json= (fun s -> `String s)
  ; decode= to_string
  ; shape= `String "string" }

let pair left right =
  { encode= (fun (a, b) -> left.encode a ^ right.encode b)
  ; json= (fun (a, b) -> `List [left.json a; right.json b])
  ; decode=
      (function
      | `List [a; b] -> (left.decode a, right.decode b)
      | _ -> fail "Invalid pair key" )
  ; shape= `List [left.shape; right.shape] }

type 'key spec =
  { id: string
  ; version: int
  ; key: 'key key
  ; map: Yojson.Safe.t -> ('key * Yojson.Safe.t) option }

type 'key view =
  { spec: 'key spec
  ; token: unit ref }

type packed_view = View : 'key view -> packed_view

type 'a page =
  { items: 'a list
  ; cursor: string option }

let mapping = Eio.Fiber.create_key ()

let access = Eio.Fiber.create_key ()

let view spec =
  if spec.id = "" || spec.version < 1
  then fail "Invalid view identity or version" ;
  {spec; token= ref ()}

let describe (View view) =
  `Assoc
    [ ("id", `String view.spec.id)
    ; ("version", `Int view.spec.version)
    ; ("key", view.spec.key.shape) ]

let validate views =
  let names = List.map (fun (View view) -> view.spec.id) views in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then fail "Duplicate view name"

let root owner = "data/" ^ component owner ^ "/"

let documents owner = root owner ^ "documents/"

let metadata owner id = root owner ^ "views/" ^ component id

let entries owner view =
  root owner
  ^ "indexes/"
  ^ component view.spec.id
  ^ "/"
  ^ string_of_int view.spec.version
  ^ "/"

let mapped view row =
  Eio.Fiber.with_binding mapping true (fun () ->
      match view.spec.map row with
      | None -> None
      | Some (key, value) ->
          Schema.check_json value ;
          let json = view.spec.key.json key in
          Schema.check_json json ;
          ignore (view.spec.key.decode json) ;
          Some (view.spec.key.encode key, json, value) )

let entry view id row =
  Option.map
    (fun (encoded, key, value) ->
      ( encoded ^ component id
      , Yojson.Safe.to_string
          (`Assoc [("key", key); ("value", value); ("document_id", `String id)])
      ) )
    (mapped view row)

let view_meta view =
  Yojson.Safe.to_string
    (`Assoc [("version", `Int view.spec.version); ("key", view.spec.key.shape)])

type t =
  { owner: string
  ; views: packed_view list
  ; read: string -> string option
  ; scan: range -> (string * string) list
  ; mutable writes: string option Strings.t
  ; token: unit ref
  ; active: bool Atomic.t }

let create ~owner ~views ~read ~scan =
  { owner
  ; views
  ; read
  ; scan
  ; writes= Strings.empty
  ; token= ref ()
  ; active= Atomic.make true }

let ensure t =
  if not (Atomic.get t.active) then fail "Expired cell database handle" ;
  if
    not
      (Option.fold
         ~none:false
         ~some:(fun token -> token == t.token)
         (Eio.Fiber.get access) )
  then fail "Database handle belongs to another operation" ;
  if Eio.Fiber.get mapping = Some true
  then fail "View mapping cannot access a database"

let with_context t f = Eio.Fiber.with_binding access t.token f

let invalidate t = Atomic.set t.active false

let changes t = Strings.bindings t.writes

let read t key =
  match Strings.find_opt key t.writes with
  | Some value -> value
  | None -> t.read key

let stage t key value = t.writes <- Strings.add key value t.writes

let scan t range =
  let changes =
    Strings.bindings t.writes |> List.filter (fun (key, _) -> matches range key)
  in
  let base = t.scan {range with limit= range.limit + List.length changes} in
  let merged =
    List.fold_left
      (fun values (key, value) ->
        match value with
        | None -> Strings.remove key values
        | Some value -> Strings.add key value values )
      (List.fold_left
         (fun values (key, value) -> Strings.add key value values)
         Strings.empty
         base )
      changes
  in
  Strings.bindings merged |> take range.limit

let get t ~id =
  ensure t ;
  Option.map
    (fun text -> member "row" (Yojson.Safe.from_string text))
    (read t (documents t.owner ^ component id))

let replace t ~id row =
  ensure t ;
  Option.iter (fun row -> Schema.validate [] row) row ;
  let old = get t ~id in
  let updates =
    List.concat_map
      (fun (View view) ->
        let prefix = entries t.owner view in
        let previous = Option.bind old (entry view id) in
        let next = Option.bind row (entry view id) in
        let delete =
          Option.to_list
            (Option.map (fun (key, _) -> (prefix ^ key, None)) previous)
        in
        let insert =
          Option.to_list
            (Option.map (fun (key, data) -> (prefix ^ key, Some data)) next)
        in
        delete
        @ insert
        @ [(metadata t.owner view.spec.id, Some (view_meta view))] )
      t.views
  in
  List.iter (fun (key, value) -> stage t key value) updates ;
  stage
    t
    (documents t.owner ^ component id)
    (Option.map
       (fun row ->
         Yojson.Safe.to_string (`Assoc [("id", `String id); ("row", row)]) )
       row )

let put t ~id row = replace t ~id (Some row)

let delete t ~id = replace t ~id None

let query ?from_key ?to_key ?after ?(limit = 100) t (view : 'key view) f =
  ensure t ;
  if limit < 1 then fail "Query limit must be positive" ;
  if not (List.exists (fun (View known) -> known.token == view.token) t.views)
  then fail "View is not registered for this cell" ;
  let prefix = entries t.owner view in
  let first =
    Option.map (fun key -> prefix ^ view.spec.key.encode key) from_key
  in
  let last =
    Option.map (fun key -> prefix ^ view.spec.key.encode key ^ "~") to_key
  in
  if
    Option.fold
      ~none:false
      ~some:(fun first ->
        Option.fold ~none:false ~some:(fun last -> first > last) last )
      first
  then fail "Invalid query range" ;
  let context =
    `List
      [ `String t.owner
      ; describe (View view)
      ; ( match first with
        | None -> `Null
        | Some key -> `String key )
      ; ( match last with
        | None -> `Null
        | Some key -> `String key ) ]
  in
  let after =
    Option.map
      (fun cursor ->
        let cursor = Yojson.Safe.from_string cursor in
        if not (Yojson.Safe.equal (member "context" cursor) context)
        then fail "Cursor belongs to another cell, view, version or range" ;
        let key = cursor |> member "after" |> to_string in
        if not (matches {prefix; first; last; after= None; limit} key)
        then fail "Invalid cursor position" ;
        key )
      after
  in
  let cursor key =
    Yojson.Safe.to_string (`Assoc [("context", context); ("after", `String key)])
  in
  let rec collect position count acc =
    let rows = scan t {prefix; first; last; after= position; limit= 128} in
    let rec consume count acc = function
      | [] ->
          if List.length rows < 128
          then {items= List.rev acc; cursor= None}
          else collect (Some (fst (List.hd (List.rev rows)))) count acc
      | (key, text) :: rest -> (
          let json = Yojson.Safe.from_string text in
          match
            f (view.spec.key.decode (member "key" json), member "value" json)
          with
          | None -> consume count acc rest
          | Some item ->
              let acc = item :: acc in
              if count + 1 = limit
              then
                let more =
                  rest <> []
                  || scan t {prefix; first; last; after= Some key; limit= 1}
                     <> []
                in
                { items= List.rev acc
                ; cursor= (if more then Some (cursor key) else None) }
              else consume (count + 1) acc rest )
    in
    consume count acc rows
  in
  collect after 0 []

let clear (backend : backend) prefix =
  let rec loop () =
    let rows =
      backend.scan {prefix; first= None; last= None; after= None; limit= 128}
    in
    if rows <> []
    then (
      backend.commit (List.map (fun (key, _) -> (key, None)) rows) ;
      loop () )
  in
  loop ()

let rebuild (backend : backend) ~owner views =
  List.concat_map
    (fun (View view) ->
      let meta = metadata owner view.spec.id in
      match backend.get meta with
      | Some text when text = view_meta view -> []
      | Some text
        when member "version" (Yojson.Safe.from_string text)
             = `Int view.spec.version ->
          fail "Changing a view key requires a new version"
      | _ ->
          let prefix = entries owner view in
          clear backend prefix ;
          let rec build after =
            let rows =
              backend.scan
                { prefix= documents owner
                ; first= None
                ; last= None
                ; after
                ; limit= 128 }
            in
            let writes =
              List.filter_map
                (fun (_, text) ->
                  let json = Yojson.Safe.from_string text in
                  let id = json |> member "id" |> to_string in
                  let row = member "row" json in
                  Option.map
                    (fun (key, value) -> (prefix ^ key, Some value))
                    (entry view id row) )
                rows
            in
            if writes <> [] then backend.commit writes ;
            if List.length rows = 128
            then build (Some (fst (List.hd (List.rev rows))))
          in
          build None ;
          [(meta, Some (view_meta view))] )
    views

(* Publish new metadata before reclaiming inactive generations. A failed build
   therefore leaves the previous version usable. *)
let prune (backend : backend) ~owner views =
  let indexes = List.map (fun (View view) -> entries owner view) views in
  let metas = List.map (fun (View view) -> metadata owner view.spec.id) views in
  let rec remove prefix keep after =
    let rows =
      backend.scan {prefix; first= None; last= None; after; limit= 128}
    in
    let writes =
      List.filter_map
        (fun (key, _) -> if keep key then None else Some (key, None))
        rows
    in
    if writes <> [] then backend.commit writes ;
    if List.length rows = 128
    then remove prefix keep (Some (fst (List.hd (List.rev rows))))
  in
  remove
    (root owner ^ "indexes/")
    (fun key ->
      List.exists (fun prefix -> String.starts_with ~prefix key) indexes )
    None ;
  remove (root owner ^ "views/") (fun key -> List.mem key metas) None
