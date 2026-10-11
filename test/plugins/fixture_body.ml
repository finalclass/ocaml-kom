open Kom
open Kom.Cell
open Kom.Schema
open Yojson.Safe.Util

let generation = Config.generation

let cache = ref (Some (Bytes.create 1024))

let cleanup () =
  cache := None ;
  match Sys.getenv_opt "KOM_TEST_CLEANUP" with
  | None -> ()
  | Some path ->
      let output =
        open_out_gen
          [Open_wronly; Open_creat; Open_append; Open_binary]
          0o600
          path
      in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> Printf.fprintf output "%d\n" generation)

let state =
  { version= Config.state_version
  ; init= (fun () -> 0)
  ; to_string= string_of_int
  ; of_string=
      (fun value ->
        match int_of_string_opt value with
        | Some n -> Ok n
        | None -> Error "Invalid counter" ) }

let values =
  Db.view
    { id= "values"
    ; version= generation
    ; key= Db.int
    ; map=
        (fun row -> Some ((member "n" row |> to_int) + (generation * 100), row))
    }

let cell =
  Cell.define
    ~revision:generation
    ~views:[Db.View values]
    { id= "counter"
    ; state
    ; operations=
        [ Transformer
            { op= "increment"
            ; input= []
            ; output= [("n", Int); ("generation", Int)]
            ; impl=
                (fun db n _ ->
                  let n = n + Config.increment in
                  Db.put db ~id:"value" (`Assoc [("n", `Int n)]) ;
                  (n, `Assoc [("n", `Int n); ("generation", `Int generation)]) )
            }
        ; Transformer
            { op= "read"
            ; input= []
            ; output= [("n", Int); ("generation", Int); ("keys", List Int)]
            ; impl=
                (fun db n _ ->
                  let page =
                    Db.query db values (fun (key, _) -> Some (`Int key))
                  in
                  ( n
                  , `Assoc
                      [ ("n", `Int n)
                      ; ("generation", `Int generation)
                      ; ("keys", `List page.items) ] ) ) }
        ; Transformer
            { op= "hold"
            ; input= [("entered", String); ("release", String)]
            ; output= [("generation", Int)]
            ; impl=
                (fun _ n msg ->
                  let entered = member "entered" msg |> to_string
                  and release = member "release" msg |> to_string in
                  Eio_unix.run_in_systhread (fun () ->
                      let output = open_out entered in
                      close_out output ) ;
                  while not (Sys.file_exists release) do
                    Eio_unix.run_in_systhread (fun () -> Unix.sleepf 0.01)
                  done ;
                  (n, `Assoc (("generation", `Int generation) :: to_assoc msg)) )
            }
        ; Transformer
            { op= "fail"
            ; input= []
            ; output= []
            ; impl= (fun _ _ _ -> failwith "Expected operation exception") } ]
    }

let flow ?(input = []) ?(output = []) id body =
  Flow.define {id; input; output; body}

let definition =
  System.define
    ~cell_kinds:[cell]
    ~init_flow:"init"
    ~flows:
      ( [ flow "init" "!reproduce counter as counter"
        ; flow
            ~output:[("n", Int); ("generation", Int)]
            "increment"
            "increment @counter"
        ; flow
            ~output:[("n", Int); ("generation", Int); ("keys", List Int)]
            "read"
            "read @counter"
        ; flow
            ~input:[("entered", String); ("release", String)]
            ~output:[("generation", Int)]
            "hold"
            "hold @counter"
        ; flow "fail" "fail @counter" ]
      @ if Config.legacy then [flow "legacy" "read @counter"] else [] )
    ()

let app =
  Kom_runtime.App.define
    ~id:"fixture"
    ~system:definition
    ~cleanup
    ~http:(fun _ request ->
      if Kom_runtime.Web.path request.target = "/"
      then Some (Kom_runtime.Web.response (string_of_int generation))
      else None )
    ()

let () =
  Kom_runtime.Plugin.register app ;
  if Config.broken then failwith "Broken initializer"
