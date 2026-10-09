module Types = Kom_contracts.Kom_types
module Message = struct
  type 'a codec = 'a Message_codec.codec
  module type Codec = Message_codec.Codec
  let schema sources = Message_codec.schema (List.map (fun (name,text) -> Cyrograf_compiler.{name;text}) sources)
  let codec = Message_codec.codec
  let type_ c = c.Message_codec.type_
  let encode c = c.Message_codec.encode
  let decode c = c.Message_codec.decode
  let bool = Message_codec.bool
  let int = Message_codec.int
  let string = Message_codec.string
  let batch items = Types.MessageBatch.make ~items ()
end
module Storage = struct
  type backend = Native_contract.backend = {load:unit -> string option;save:string -> unit;close:unit -> unit}
  type t = Native_contract.storage = Memory | Backend of string * (string -> backend)
  let memory = Native_contract.Memory
  let backend ?(location="native") f = Native_contract.Backend (location,f)
end
module Flow = struct
  open Types
  type t = FlowDefinition.t
  type named = NamedFlow.t
  type source = ValueSource.t
  type binding = InputBinding.t
  type pattern = OutputPattern.t
  type case = pattern * t
  let next = Atomic.make 0
  let fresh () = "@" ^ string_of_int (Atomic.fetch_and_add next 1)
  let input = ValueSource.Input
  let output from = ValueSource.Output from
  let field ?from fields = ValueSource.Field (FieldSource.make ?node_id:from ~fields ())
  let constant codec value = ValueSource.Constant (codec.Message_codec.encode value)
  let bind s = InputBinding.Whole s
  let bind_fields fields = InputBinding.Fields (List.map (fun (target_fields,source) -> FieldBinding.make ~target_fields ~source ()) fields)
  let leaf ?id body = let id=Option.value ~default:(fresh ()) id in
    FlowDefinition.make ~root_id:id ~nodes:[FlowNode.make ~id ~body ()] ()
  let step ?id ~cell ~operation ?(input=bind input) () =
    leaf ?id (NodeBody.Step (StepNode.make ~cell_id:cell ~operation ~input ()))
  let use ~as_ ?(input=bind input) named =
    leaf ~id:as_ (NodeBody.Use (UseNode.make ~flow_id:named.NamedFlow.id ~input ()))
  let structure body ts =
    let id=fresh () in
    FlowDefinition.make ~root_id:id ~nodes:(FlowNode.make ~id ~body () :: List.concat_map (fun t -> t.FlowDefinition.nodes) ts) ()
  let sequence ts = structure (NodeBody.Sequence (NodeList.make ~nodes:(List.map (fun t -> t.FlowDefinition.root_id) ts) ())) ts
  let parallel ts = structure (NodeBody.Parallel (NodeList.make ~nodes:(List.map (fun t -> t.FlowDefinition.root_id) ts) ())) ts
  let bool value = OutputPattern.BoolValue value
  let constructor codec ~tag = Message_codec.constructor codec tag
  let case ~output flow = output,flow
  let branch ~from ?default cases =
    let roots=List.map (fun (output,t) -> BranchCase.make ~output ~node_id:t.FlowDefinition.root_id ()) cases in
    let ts=List.map snd cases @ Option.to_list default in
    structure (NodeBody.Branch (BranchNode.make ~from ~cases:roots ?default_node_id:(Option.map (fun t -> t.FlowDefinition.root_id) default) ())) ts
  let input_type codec t = {t with FlowDefinition.input_type=Some codec.Message_codec.type_}
  let define ~id ?(version=1) definition = NamedFlow.make ~id ~version ~definition ()
  let inline t = FlowSelector.Inline t
  let named id = FlowSelector.Id id
end
exception Error of Types.Problems.t
let create_internal ~scheduler ~storage ~id ~max_attempts definition =
  match Revision_manager.create ~scheduler ~storage ~id definition with
  | Error p -> raise (Error p)
  | Ok revision ->
    let store=revision.Revision_manager.store and flows=revision.flows and engine=revision.engine and bus=revision.bus in
    let execution=Execution_manager.{store;flows;engine;scheduler;bus;max_attempts} in
    let system=Native_contract.{id;scheduler;storage;
      send=(fun entry -> Execution_manager.send execution entry);
      await=(fun receipt -> Execution_manager.await execution receipt);
      update=(fun ~force def -> Revision_manager.update revision ~force def);
      instantiate=(fun spec cell -> Revision_manager.instantiate revision spec cell);
      close=(fun () -> Revision_manager.close revision)} in
    Execution_ingress_client.register bus execution;
    Message_bus.admission bus;
    Message_bus.work bus;
    system
let () = Hosting.set_factory (fun ~scheduler ~storage ~id definition -> create_internal ~scheduler ~storage ~id ~max_attempts:1 definition)
module Context = struct
  type t = Native_contract.context
  let work_id ctx = ctx.Native_contract.work_id
  let execution_id ctx = ctx.Native_contract.execution_id
  let cell_id ctx = ctx.Native_contract.cell_id
  let child ctx ~id definition = ctx.Native_contract.child ~id definition
  let call ctx ~call_id system ~flow message = ctx.Native_contract.call ~call_id system flow message
end
module Cell = struct
  type definition = Native_contract.cell
  type 'a restoration = 'a Native_contract.restoration = Restored of 'a | Unsupported of Types.Problem.t | Failed of Types.Problem.t
  module type S = Native_contract.Cell
  let define (module C : S) = Native_contract.Cell {
    id=C.id;revision=C.revision;state_version=C.state_version;operations=C.operations;
    init=C.init;handle=C.handle;snapshot=C.snapshot;restore=C.restore;release=C.release }
  let spec ~id ?(configuration=`Assoc []) definition =
    let Native_contract.Cell c=definition in
    let implementation=Types.ImplementationRef.make ~id:c.id ~revision:c.revision () in
    Types.CellSpec.make ~id ~implementation ~configuration (),definition
  let instantiate system ~id ?configuration definition =
    let wire,_=spec ~id ?configuration definition in system.Native_contract.instantiate wire definition
end
module Operation = struct
  let make ~name ~input ~outputs = Types.Operation.make ~name ~input:(Message.type_ input) ~outputs ()
end
module System = struct
  type t = Native_contract.system
  type definition = Native_contract.definition
  let define ?(implementations=[]) ~cells ~flows () =
    Native_contract.{wire=Types.SystemDefinition.make ~cells:(List.map fst cells) ~flows ();
      implementations=List.map snd cells @ implementations}
  let create ?(id=Hosting.uuid ()) ?(workers=4) ?(max_attempts=1) ?(storage=Storage.memory) definition =
    if max_attempts<1 then invalid_arg "max_attempts must be positive";
    try
      let scheduler=Scheduler.create workers in
      let sys=create_internal ~scheduler ~storage ~id ~max_attempts definition in
      at_exit (fun () -> sys.close (); Scheduler.drain scheduler);
      Ok sys
    with
    | Error p -> Result.Error p
    | Message_codec.Invalid p -> Result.Error (Types.Problems.make ~items:[p] ())
    | exn -> Result.Error (Types.Problems.make ~items:[Message_codec.problem "Exception" (Printexc.to_string exn)] ())
  let with_ ?id ?workers ?max_attempts ?storage definition f =
    match create ?id ?workers ?max_attempts ?storage definition with
    | Error p -> Result.Error p
    | Ok sys -> Ok (Fun.protect (fun () -> f sys) ~finally:(fun () -> sys.close (); Scheduler.drain sys.scheduler))
  let send sys ~flow message =
    let entry=Types.Entry.make ~id:(Hosting.uuid ()) ~system:(Types.SystemRef.make ~id:sys.Native_contract.id ()) ~flow ~message () in
    sys.send entry
  let await sys receipt = sys.Native_contract.await receipt
  let call sys ~flow message = match send sys ~flow message with
    | Types.SendResponse.Rejected ps -> Result.Error ps
    | Admitted r | Buffered r -> (match await sys r with
      | Types.AwaitResponse.Finished completion -> Ok completion
      | UnknownReceipt -> Result.Error (Types.Problems.make ~items:[Message_codec.problem "Receipt" "Unknown receipt"] ()))
  let update ?(force=false) sys definition = sys.Native_contract.update ~force definition
end
