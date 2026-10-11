open Yojson.Safe.Util

let with_field name value json =
  `Assoc ((name, value) :: List.remove_assoc name (to_assoc json))

open Kom
open Cell
open Schema

let state =
  { version= 1
  ; init= (fun () -> 0)
  ; to_string= string_of_int
  ; of_string=
      (fun s ->
        try Ok (int_of_string s) with
        | _ -> Result.Error "invalid counter" ) }

let definition ?marker ?(transactional = false) () =
  let counter =
    Cell.define
      { id= "counter"
      ; state
      ; operations=
          [ Transformer
              { op= "inc"
              ; input= []
              ; output= [("n", Int)]
              ; impl=
                  (fun db n m ->
                    Db.put db ~id:"counter" (`Assoc [("n", `Int (n + 1))]) ;
                    (n + 1, with_field "n" (`Int (n + 1)) m) ) }
          ; Transformer
              { op= "read"
              ; input= []
              ; output= [("n", Int)]
              ; impl=
                  (fun db n m ->
                    let stored =
                      Option.value
                        ~default:(`Assoc [("n", `Int 0)])
                        (Db.get db ~id:"counter")
                    in
                    if member "n" stored <> `Int n
                    then failwith "state/document atomicity violated" ;
                    (n, with_field "n" (`Int n) m) ) } ] }
  in
  let gate =
    Cell.define
      { id= "gate"
      ; state= unit_state
      ; operations=
          [ Transformer
              { op= "finish"
              ; input= [("n", Int)]
              ; output= []
              ; impl=
                  (fun _db () m ->
                    Option.iter
                      (fun path ->
                        let channel = open_out path in
                        output_string channel "ready" ;
                        close_out channel ;
                        Eio.Fiber.await_cancel () )
                      marker ;
                    ((), m) ) } ] }
  in
  let flow id output body = Flow.define {id; input= []; output; body} in
  System.define
    ~cell_kinds:[counter; gate]
    ~init_flow:"init"
    ~flows:
      [ flow
          "init"
          []
          "!sequence(!reproduce counter as counter !reproduce gate as gate)"
      ; flow
          "work"
          [("n", Int)]
          ( if transactional
            then "!transaction(!sequence(inc @counter finish @gate))"
            else "!sequence(inc @counter finish @gate)" )
      ; flow "read" [("n", Int)] "read @counter" ]
    ()
