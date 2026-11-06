open Kom

module Example = struct
  module State = struct
    type t = int [@@deriving yojson]

    let version = 1

    let init () = 0
  end

  module Input = struct
    type t = {name: string} [@@deriving kom]
  end

  module Empty = struct
    type t = unit [@@deriving kom]
  end

  module Output = struct
    type t = {greeting: string} [@@deriving kom]
  end

  let format name = "Hello, " ^ name

  let greet _db (state : State.t) (msg : Input.t Kom.Msg.t) : State.t * Output.t
      =
    (state + 1, {greeting= format (Msg.data msg).name})
  [@@kom.transformer {output= patch; remove= ["temporary"]}]

  let split _db (state : State.t) (_msg : Empty.t Kom.Msg.t) :
      State.t * Output.t list =
    (state, [{greeting= "one"}; {greeting= "two"}])
  [@@kom.expander {output= fresh}]

  let join _db (state : State.t) (messages : Output.t Kom.Msg.t list) :
      State.t * Output.t =
    ( state
    , { greeting=
          String.concat
            ","
            (List.map (fun msg -> (Msg.data msg).Output.greeting) messages) } )
  [@@kom.joiner {output= fresh}]

  let select _db (state : State.t) (messages : Output.t Kom.Msg.t list) :
      State.t * (Output.t Kom.Msg.t * Output.t) =
    match messages with
    | first :: _ -> (state, (first, {greeting= "selected"}))
    | [] -> failwith "empty"
  [@@kom.joiner {output= patch_selected}]

  let route _db (state : State.t) (_msg : Empty.t Kom.Msg.t) :
      State.t * (string * Empty.t) =
    (state, ("yes", ()))
  [@@kom.router {id= "choose"; output= patch; ports= ["yes"; "no"]}]
end
[@@kom.cell {id= "Decorated"}]

(* Attributes also work independently, without a cell module. *)
let standalone _db (state : Example.State.t) (_msg : Example.Empty.t Kom.Msg.t)
    : Example.State.t * Example.Empty.t =
  (state, ())
[@@kom.transformer {output= patch}]

module Default_name = struct
  module State = Example.State
  module Empty = Example.Empty

  let touch _db (state : State.t) (_msg : Empty.t Kom.Msg.t) : State.t * Empty.t
      =
    (state, ())
  [@@kom.transformer {output= patch}]
end
[@@kom.cell]

let () =
  let _ : int Cell.operation = standalone_operation in
  let flows =
    List.map
      (fun (id, body) -> Flow.define ~id ~body ())
      [ ( "init"
        , "!reproduce Decorated as @g; !reproduce Default_name as @default" )
      ; ("greet", "greet @g")
      ; ("sum", "split @g; join @g")
      ; ("select", "split @g; select @g")
      ; ("route", "!branch(choose @g; yes(greet @g); no(greet @g))")
      ; ("touch", "touch @default") ]
  in
  let definition =
    System.define
      ~cell_kinds:[Example.cell; Default_name.cell]
      ~init_flow:"init"
      ~flows
      ()
  in
  Kom.run definition (fun sys ->
      let message =
        Msg.define
          [("name", `String "Jan"); ("temporary", `Bool true); ("extra", `Int 1)]
      in
      let greet = System.call sys ~flow:"greet" ~msg:message in
      assert (Msg.id greet = Msg.id message) ;
      assert (Yojson.Safe.Util.member "temporary" (Msg.raw greet) = `Null) ;
      assert (Yojson.Safe.Util.member "extra" (Msg.raw greet) = `Int 1) ;
      let text msg =
        (Msg.data (Msg.decode (module Example.Output) msg)).greeting
      in
      assert (text greet = "Hello, Jan") ;
      assert (text (System.call sys ~flow:"sum" ~msg:message) = "one,two") ;
      assert (text (System.call sys ~flow:"select" ~msg:message) = "selected") ;
      assert (text (System.call sys ~flow:"route" ~msg:message) = "Hello, Jan") ;
      ignore (System.call sys ~flow:"touch" ~msg:message) ) ;
  print_endline
    "PASS decorated cells, standalone operations, all operation kinds and \
     output policies"
