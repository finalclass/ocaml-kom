open Kom_contracts.Kom_types
module Codec = Message_codec
let fail = Codec.fail
let operation cells cell_id name =
  let c=match List.find_opt (fun (c : CellBinding.t) -> c.cell_id=cell_id) cells with
    | Some c -> c | None -> fail "Flow" ("Unknown cell: " ^ cell_id) in
  match List.find_opt (fun (o : Operation.t) -> o.name=name) c.definition.operations with
  | Some o -> o | None -> fail "Flow" ("Unknown operation: " ^ name)
let node def id = match List.find_opt (fun (n : FlowNode.t) -> n.id=id) def.FlowDefinition.nodes with
  | Some n -> n | None -> fail "Flow" ("Missing node: " ^ id)
let children = function
  | NodeBody.Step _ | Use _ -> []
  | Sequence ns | Parallel ns -> ns.NodeList.nodes
  | Branch b -> List.map (fun (c : BranchCase.t) -> c.node_id) b.cases @ Option.to_list b.default_node_id
let check_tree def =
  let ids=List.map (fun (n : FlowNode.t) -> n.id) def.FlowDefinition.nodes in
  if List.length ids <> List.length (List.sort_uniq String.compare ids) then fail "Flow" "Duplicate node ID";
  let visited=ref [] in
  let rec visit stack id =
    if List.mem id stack then fail "Flow" "AST cycle";
    if List.mem id !visited then fail "Flow" "Shared child is not a tree";
    visited := id :: !visited;
    List.iter (visit (id::stack)) (children (node def id).body) in
  visit [] def.root_id;
  if List.length !visited <> List.length ids then fail "Flow" "Unreachable AST node"
let unique xs = List.sort_uniq compare xs
let get_output env id = match List.assoc_opt id env with
  | Some xs -> xs | None -> fail "Binding" ("Unavailable output: " ^ id)
let validate_fields target bindings source =
  let paths=List.map (fun (b : FieldBinding.t) -> b.target_fields) bindings in
  let rec prefix a b = match a,b with [],_ -> true | x::xs,y::ys when x=y -> prefix xs ys | _ -> false in
  List.iteri (fun i p -> List.iteri (fun j q ->
    if i<>j && prefix p q then fail "Binding" "Overlapping target fields") paths) paths;
  List.iter (fun (b : FieldBinding.t) ->
    let ty=Codec.project_type target b.target_fields in
    if List.exists (fun s -> s<>ty) (source b.source) then fail "Binding" "Field type mismatch") bindings;
  let rec covered ty path =
    if List.mem path paths then () else
      let d=Codec.descriptor ty in match d.ty with
      | Cyrograf.Schema.Optional _ -> ()
      | Cyrograf.Schema.Reference _ ->
        List.iter (fun (f : Cyrograf.Schema.field) ->
          let next=path@[f.name] in covered (Codec.project_type target next) next) (Codec.fields ty)
      | _ -> fail "Binding" "Missing required target field" in
  covered target []
let validate ~catalog ~flows ~system definition =
  let deps=Hashtbl.create 16 in
  let rec analyze stack def =
    check_tree def;
    let input=ref def.FlowDefinition.input_type in
    let narrowings=ref [] in
    let constrain t = if t<>Codec.any then match !input with
      | None -> input := Some t | Some existing when existing=t -> ()
      | Some _ -> fail "Binding" "Conflicting Flow input types" in
    let rec source env ?expected = function
      | ValueSource.Input ->
        Option.iter constrain expected;
        [Option.value ~default:Codec.any !input]
      | Output id -> get_output env id
      | Constant m -> Codec.validate m; [m.Message.type']
      | Field f ->
        let ts=match f.FieldSource.node_id with
          | None -> (match !input with Some t -> [t] | None -> fail "Binding" "Field(Input) requires an explicit input_type")
          | Some id -> get_output env id in
        let constructors=Option.bind f.node_id (fun id -> List.assoc_opt id !narrowings) in
        List.map (fun t -> Codec.project_type ?constructors t f.fields) ts |> unique
    and binding env expected = function
      | InputBinding.Whole s ->
        let ts=source env ~expected s in
        if expected<>Codec.any && List.exists (fun t -> t<>expected) ts then fail "Binding" "Input binding type mismatch"
      | Fields bs -> validate_fields expected bs (source env)
    and walk env id =
      let n=node def id in match n.body with
      | NodeBody.Step s ->
        let o=operation system.SystemView.cells s.cell_id s.operation in
        ignore (Codec.descriptor o.input); List.iter (fun t -> ignore (Codec.descriptor t)) o.outputs;
        binding env o.input s.input;
        o.outputs, (id,o.outputs)::env
      | Use u ->
        if List.mem u.flow_id stack then fail "Flow" "Flow dependency cycle";
        let named=match Hashtbl.find_opt deps u.flow_id with
          | Some (f,_) -> f
          | None -> Flow_access.resolve flows catalog u.flow_id in
        let normalized,outs=analyze (u.flow_id::stack) named.definition in
        let named={named with NamedFlow.definition=normalized} in
        Hashtbl.replace deps u.flow_id (named,outs);
        binding env (Option.value ~default:Codec.any normalized.input_type) u.input;
        outs, (id,outs)::env
      | Sequence ns ->
        List.fold_left (fun (_,env) id -> walk env id)
          ([Option.value ~default:Codec.any !input],env) ns.nodes
      | Parallel ns ->
        let results=List.map (walk env) ns.nodes in
        List.concat_map fst results,
        List.concat_map (fun (_,e) -> List.filter (fun (id,_) -> not (List.mem_assoc id env)) e) results @ env
      | Branch b ->
        (match b.from with ValueSource.Output _ | Field {node_id=Some _;_} -> ()
          | _ -> fail "Branch" "Branch must reference a Step or Use output");
        let types=source env b.from in
        let possible=List.concat_map Codec.patterns types |> unique in
        let cases=List.map (fun (c : BranchCase.t) -> c.output) b.cases in
        if List.length cases <> List.length (unique cases) then fail "Branch" "Duplicate or overlapping case";
        if List.exists (fun c -> not (List.mem c possible)) cases then fail "Branch" "Impossible branch case";
        if b.default_node_id=None && List.exists (fun c -> not (List.mem c cases)) possible then fail "Branch" "Missing output coverage";
        let visit patterns child =
          let old = !narrowings in
          (match b.from with ValueSource.Output id ->
            let tags=List.filter_map (function OutputPattern.Constructor c -> Some c.tag | _ -> None) patterns in
            if tags<>[] then narrowings := (id,tags)::old
            | _ -> ());
          Fun.protect (fun () -> fst (walk env child)) ~finally:(fun () -> narrowings := old) in
        let cases_out=List.concat_map (fun (c : BranchCase.t) -> visit [c.output] c.node_id) b.cases in
        let default_out=match b.default_node_id with None -> [] | Some id ->
          visit (List.filter (fun p -> not (List.mem p cases)) possible) id in
        let ts=unique (cases_out @ default_out) in
        ts,env in
    let outs,_=walk [] def.root_id in
    {def with FlowDefinition.input_type = !input},outs in
  let definition,output_types=analyze [] definition in
  let dependencies=Hashtbl.fold (fun _ (f,_) xs -> f::xs) deps []
    |> List.sort (fun (a : NamedFlow.t) b -> String.compare a.id b.id) in
  ValidatedFlow.make ~definition ~dependencies ~system_revision:system.revision
    ~input_type:(Option.value ~default:Codec.any definition.input_type) ~output_types ~cells:system.cells ()
let qualify scope id = Yojson.Safe.to_string (`List (List.map (fun s -> `String s) (scope@[id])))
let single = function [m] -> m | _ -> fail "Binding" "Output requires exactly one message"
let source input env = function
  | ValueSource.Input -> input
  | Output id -> single (get_output env id)
  | Constant m -> Codec.validate m; m
  | Field f ->
    let value=match f.FieldSource.node_id with None -> input | Some id -> single (get_output env id) in
    Codec.project value f.fields
let bind input env expected = function
  | InputBinding.Whole s -> let m=source input env s in Codec.accepts expected m; m
  | Fields bs -> Codec.construct expected (List.map (fun (b : FieldBinding.t) -> b.target_fields,source input env b.source) bs)
let encode_checkpoint c = FlowProgress.make ~format_version:1 ~data:(Codec.unwrap (FlowCheckpoint.to_drut c)) ()
let decode_checkpoint p =
  if p.FlowProgress.format_version<>1 then fail "Checkpoint" "Unsupported checkpoint version";
  Codec.unwrap (FlowCheckpoint.from_drut p.data)
let dependency (flow : ValidatedFlow.t) id =
  match List.find_opt (fun (f : NamedFlow.t) -> f.id=id) flow.dependencies with
  | Some f -> f | None -> fail "Checkpoint" "Missing pinned fragment"
let plan (flow : ValidatedFlow.t) (checkpoint : FlowCheckpoint.t) =
  let pending=ref checkpoint.pending and added=ref [] in
  let rec eval def scope path input env id =
    let n=node def id in
    let qualified=qualify scope id in
    match n.body with
    | NodeBody.Step s ->
      (match List.find_opt (fun (r : NodeResult.t) -> r.node_id=qualified) checkpoint.results with
      | Some r -> Some r.messages.items, (id,r.messages.items)::env
      | None ->
        if not (List.exists (fun (w : Work.t) -> w.node_id=qualified) !pending) then (
          let o=operation flow.cells s.cell_id s.operation in
          let message=bind input env o.input s.input in
          let w=Work.make ~id:qualified ~node_id:qualified ~branch_path:path ~cell_id:s.cell_id ~operation:s.operation ~message () in
          pending := !pending@[w]; added := !added@[w]);
        None,env)
    | Use u ->
      let fragment=(dependency flow u.flow_id).definition in
      let input=bind input env (Option.value ~default:Codec.any fragment.input_type) u.input in
      let out,_=eval fragment (scope@[id]) path input [] fragment.root_id in
      out,(match out with None -> env | Some ms -> (id,ms)::env)
    | Sequence ns ->
      let rec sequence env previous = function
        | [] -> Some previous,env
        | child::tail -> let out,env=eval def scope path input env child in
          match out with None -> None,env | Some ms -> sequence env ms tail in
      sequence env [input] ns.nodes
    | Parallel ns ->
      let results=List.mapi (fun index child -> eval def scope (path@[qualify scope id;string_of_int index]) input env child) ns.nodes in
      if List.exists (fun (out,_) -> out=None) results then None,env
      else Some (List.concat_map (fun (out,_) -> Option.get out) results),
        List.concat_map (fun (_,e) -> List.filter (fun (id,_) -> not (List.mem_assoc id env)) e) results @ env
    | Branch b ->
      let value=source input env b.from in Codec.validate value;
      let cases=List.filter (fun (c : BranchCase.t) -> Codec.matches c.output value) b.cases in
      let child=match cases with [c] -> c.node_id
        | [] -> (match b.default_node_id with Some id -> id | None -> fail "Branch" "No matching case")
        | _ -> fail "Branch" "Ambiguous branch case" in
      let out,_=eval def scope path input env child in out,env in
  let output,_=eval flow.definition [] [] checkpoint.input [] flow.definition.root_id in
  let progress=encode_checkpoint {checkpoint with pending = !pending} in
  let completion=Option.map (fun items -> Completion.Completed (MessageBatch.make ~items ())) output in
  Advancement.make ~progress ~work:!added ?completion ()
let start flow message =
  Codec.accepts flow.ValidatedFlow.input_type message;
  let checkpoint=FlowCheckpoint.make ~input:message ~results:[] ~pending:[] () in
  let a=plan flow checkpoint in
  ExecutionPlan.make ~flow ~progress:a.progress ~work:a.work ?completion:a.completion ()
let advance flow progress (output : StepOutput.t) =
  let cp=decode_checkpoint progress in
  let work=match List.find_opt (fun (w : Work.t) -> w.id=output.work_id) cp.pending with
    | Some w -> w | None -> fail "Checkpoint" "Unknown or already settled work" in
  if work.node_id<>output.node_id || work.branch_path<>output.branch_path then fail "Checkpoint" "Work identity mismatch";
  let o=operation flow.ValidatedFlow.cells work.cell_id work.operation in
  List.iter (fun (m : Message.t) ->
    if not (List.mem m.type' o.outputs) then fail "Contract" "Undeclared output";
    Codec.validate m) output.messages.items;
  let result=NodeResult.make ~node_id:work.node_id ~messages:output.messages () in
  plan flow {cp with results=cp.results@[result];pending=List.filter (fun (w : Work.t) -> w.id<>work.id) cp.pending}
