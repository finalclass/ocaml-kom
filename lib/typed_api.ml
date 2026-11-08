open Native_contract

module type Data = sig
  type t

  val kom : t Codec.t
end

module Msg = struct
  type 'a t =
    { message: message
    ; data: 'a }

  let serial = Atomic.make 0

  let fresh_id () =
    Printf.sprintf
      "msg-%d-%.9f-%d"
      (Unix.getpid ())
      (Unix.gettimeofday ())
      (Atomic.fetch_and_add serial 1)

  let of_message message = {message; data= message.body}

  let message msg = msg.message

  let data msg = msg.data

  let raw msg = msg.message.body

  let id msg = msg.message.id

  let of_json ?id body =
    Schema.validate [] body ;
    let id = Option.value ~default:(fresh_id ()) id in
    if id = "" then fail "Identity" "Empty message ID" ;
    of_message {id; body}

  let define ?id fields = of_json ?id (`Assoc fields)

  let decode (type a) (module D : Data with type t = a) msg =
    Schema.validate (Codec.fields D.kom) (raw msg) ;
    match Codec.decode D.kom (raw msg) with
    | Ok data -> {message= msg.message; data}
    | Result.Error error -> fail "Contract" error

  let encode (type a) (module D : Data with type t = a) data =
    of_json (Codec.encode D.kom data)
end

module Route = struct
  type 'a t =
    { ports: (string * Schema.fields) list
    ; split: 'a -> string * Yojson.Safe.t }

  let define ports split =
    let names = List.map fst ports in
    if
      ports = []
      || List.mem "" names
      || List.length names <> List.length (List.sort_uniq String.compare names)
    then fail "Router" "Empty or duplicate output port" ;
    {ports; split}

  let ports route = route.ports

  let split route value = route.split value
end

module type Route = sig
  type t

  val route : t Route.t
end

module Output = struct
  type single = [`Single]

  type group = [`Group]

  type route = [`Route]

  (* [apply] returns the output port with the message. Single-port policies
     use the port named "output". *)
  type ('input, 'result, 'scope) t =
    { outputs: (string * Schema.fields) list
    ; output_mode: output_mode
    ; apply: message list -> 'result -> string * message }

  let single fields = [("output", fields)]

  let encoded codec value =
    let body = Codec.encode codec value in
    Schema.validate (Codec.fields codec) body ;
    body

  let patch_body remove (base : message) body =
    let output = Yojson.Safe.Util.to_assoc body in
    let previous = Yojson.Safe.Util.to_assoc base.body in
    { base with
      body=
        `Assoc
          ( output
          @ List.filter
              (fun (name, _) ->
                not (List.mem name remove || List.mem_assoc name output) )
              previous ) }

  let check_remove fields remove =
    if List.exists (fun name -> name = "" || List.mem_assoc name fields) remove
    then
      fail
        "Contract"
        "Removed fields must be nonempty and disjoint from output fields" ;
    if List.length remove <> List.length (List.sort_uniq String.compare remove)
    then fail "Contract" "Duplicate removed field"

  let patch (type a) ?(remove = []) (module D : Data with type t = a) :
      ('i, a, single) t =
    let fields = Codec.fields D.kom in
    check_remove fields remove ;
    { outputs= single fields
    ; output_mode= Patch remove
    ; apply=
        (fun messages value ->
          match messages with
          | [base] -> ("output", patch_body remove base (encoded D.kom value))
          | _ -> fail "Shape" "Patch requires one input message" ) }

  let fresh (type a) (module D : Data with type t = a) :
      ('i, a, [< single | group]) t =
    { outputs= single (Codec.fields D.kom)
    ; output_mode= Fresh
    ; apply=
        (fun _ value ->
          ("output", {id= Msg.fresh_id (); body= encoded D.kom value}) ) }

  let routed (type a) (module R : Route with type t = a) value =
    let port, body = Route.split R.route value in
    match List.assoc_opt port (Route.ports R.route) with
    | Some fields ->
        Schema.validate fields body ;
        (port, body)
    | None -> fail "Router" ("Undeclared port: " ^ port)

  let patch_route (type a) ?(remove = []) (module R : Route with type t = a) :
      ('i, a, route) t =
    let outputs = Route.ports R.route in
    List.iter (fun (_, fields) -> check_remove fields remove) outputs ;
    { outputs
    ; output_mode= Patch remove
    ; apply=
        (fun messages value ->
          let port, body = routed (module R) value in
          match messages with
          | [base] -> (port, patch_body remove base body)
          | _ -> fail "Shape" "Patch requires one input message" ) }

  let fresh_route (type a) (module R : Route with type t = a) : ('i, a, route) t
      =
    { outputs= Route.ports R.route
    ; output_mode= Fresh
    ; apply=
        (fun _ value ->
          let port, body = routed (module R) value in
          (port, {id= Msg.fresh_id (); body}) ) }

  let patch_selected (type a) ?(remove = []) (module D : Data with type t = a) :
      ('i, 'i Msg.t * a, group) t =
    let fields = Codec.fields D.kom in
    check_remove fields remove ;
    { outputs= single fields
    ; output_mode= Selected remove
    ; apply=
        (fun messages (selected, value) ->
          let base = Msg.message selected in
          if not (List.exists (fun message -> message == base) messages)
          then
            fail
              "Identity"
              "Selected base must be one of this Joiner's input messages" ;
          ("output", patch_body remove base (encoded D.kom value)) ) }
end

module Cell = struct
  module Raw = Raw_cell

  module type State = sig
    type t

    val version : int

    val init : unit -> t

    val to_yojson : t -> Yojson.Safe.t

    val of_yojson : Yojson.Safe.t -> (t, string) result
  end

  type 'state operation = 'state Native_contract.operation

  type 'state spec =
    { id: string
    ; state: (module State with type t = 'state)
    ; operations: 'state operation list }

  type definition = Native_contract.cell

  let raw operation = Native_contract.Raw operation

  let define (type s) ?(views = []) ?(revision = 1) (spec : s spec) =
    let module S = (val spec.state) in
    let state =
      { version= S.version
      ; init= S.init
      ; to_string= (fun value -> Yojson.Safe.to_string (S.to_yojson value))
      ; of_string= (fun text -> S.of_yojson (Yojson.Safe.from_string text)) }
    in
    let cell =
      Native_contract.Cell
        (views, revision, {id= spec.id; state; operations= spec.operations})
    in
    Cell_code_access.validate cell ;
    cell

  let one = function
    | Message m -> m
    | _ -> fail "Shape" "Expected one message"

  let many = function
    | Group values -> List.map one values
    | _ -> fail "Shape" "Expected a flat group"

  let view input message = Msg.decode input (Msg.of_message message)

  let transformer
      (type i r)
      ~id
      ~(input : (module Data with type t = i))
      ~(output : (i, r, Output.single) Output.t)
      ~impl =
    let module I = (val input) in
    Typed
      { op= id
      ; input= Codec.fields I.kom
      ; outputs= output.outputs
      ; output_mode= output.output_mode
      ; shape= One
      ; impl=
          (fun db state value ->
            let message = one value in
            let next, result = impl db state (view input message) in
            (next, Message (snd (output.apply [message] result))) ) }

  let expander
      (type i r)
      ~id
      ~(input : (module Data with type t = i))
      ~(output : (i, r, Output.single) Output.t)
      ~impl =
    let module I = (val input) in
    Typed
      { op= id
      ; input= Codec.fields I.kom
      ; outputs= output.outputs
      ; output_mode= output.output_mode
      ; shape= Many
      ; impl=
          (fun db state value ->
            let message = one value in
            let next, results = impl db state (view input message) in
            ( next
            , Group
                (List.map
                   (fun result ->
                     let _, result = output.apply [message] result in
                     Message {result with id= Msg.fresh_id ()} )
                   results ) ) ) }

  let joiner
      (type i r)
      ~id
      ~(input : (module Data with type t = i))
      ~(output : (i, r, Output.group) Output.t)
      ~impl =
    let module I = (val input) in
    Typed
      { op= id
      ; input= Codec.fields I.kom
      ; outputs= output.outputs
      ; output_mode= output.output_mode
      ; shape= Join
      ; impl=
          (fun db state value ->
            let messages = many value in
            let next, result = impl db state (List.map (view input) messages) in
            (next, Message (snd (output.apply messages result))) ) }

  let router
      (type i r)
      ~id
      ~(input : (module Data with type t = i))
      ~(output : (i, r, Output.route) Output.t)
      ~impl =
    let module I = (val input) in
    Typed
      { op= id
      ; input= Codec.fields I.kom
      ; outputs= output.outputs
      ; output_mode= output.output_mode
      ; shape= Route
      ; impl=
          (fun db state value ->
            let message = one value in
            let next, result = impl db state (view input message) in
            let port, message = output.apply [message] result in
            (next, Port (port, message)) ) }
end
