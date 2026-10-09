open Kom_contracts.Kom_types
module S = Cyrograf.Schema
exception Invalid of Problem.t
let problem ?path code message = Problem.make ~code ~message ?path ()
let fail ?path code message = raise (Invalid (problem ?path code message))
let unwrap = function Ok x -> x | Error (e : Cyrograf.Error.t) -> fail "Codec" e.message
let json text = try Yojson.Safe.from_string text with _ -> fail "Codec" "Invalid Drut text"
let text = Yojson.Safe.to_string
let key (t : MessageType.t) = t.name ^ "#" ^ t.schema_hash
let equal (a : MessageType.t) b = a = b
let any = MessageType.make ~name:"Kom.Any" ~schema_hash:"unconstrained" ()
type descriptor = { schema : S.t; ty : S.type_ }
type 'a codec = { type_ : MessageType.t; encode : 'a -> Message.t; decode : Message.t -> 'a }
let descriptors : (string, descriptor) Hashtbl.t = Hashtbl.create 64
let validators : (string, string -> unit) Hashtbl.t = Hashtbl.create 64
let lock = Mutex.create ()
let synchronized f = Mutex.lock lock; Fun.protect ~finally:(fun () -> Mutex.unlock lock) f
let schema sources = match Cyrograf_compiler.compile ~sources with
  | Ok s -> s
  | Error es -> fail "Schema" (String.concat "; " (List.map (fun (e : Cyrograf.Error.t) -> e.message) es))
let rec type_name = function
  | S.Reference q -> S.qualified_name q
  | S.Primitive p -> S.primitive_name p
  | S.List t -> "List<" ^ type_name t ^ ">"
  | S.Optional t -> "Optional<" ^ type_name t ^ ">"
let rec references = function
  | S.Reference q -> [q]
  | S.List t | S.Optional t -> references t
  | _ -> []
let identity schema ty =
  let rec collect seen = function
    | [] -> seen
    | q :: qs when List.mem q seen -> collect seen qs
    | q :: qs ->
      let m = match S.find_message schema q with Some m -> m | None -> fail "Schema" "Unknown message" in
      let ts = match m.kind with S.Struct fs -> List.map (fun (f : S.field) -> f.type_) fs
        | S.Variant cs -> List.map (fun (c : S.constructor) -> c.payload) cs in
      collect (q :: seen) (List.concat_map references ts @ qs) in
  let names = collect [] (references ty) in
  let modules = List.filter_map (fun (m : S.module_) ->
    let messages = List.filter (fun (v : S.message) -> List.mem S.{module_name=m.name; message_name=v.name} names) m.messages in
    if messages = [] then None else Some {m with messages; methods=[]}) schema.S.modules in
  let canonical = Cyrograf_compiler.Descriptor.schema_json S.{modules} in
  MessageType.make ~name:(type_name ty) ~schema_hash:(Digest.to_hex (Digest.string (type_name ty ^ canonical))) ()
let register_descriptor schema ty =
  let t = identity schema ty in
  synchronized (fun () -> Hashtbl.replace descriptors (key t) {schema;ty}); t
let descriptor t = synchronized (fun () -> match Hashtbl.find_opt descriptors (key t) with
  | Some d -> d | None -> fail "Descriptor" ("Unknown descriptor: " ^ t.MessageType.name))
let message_kind d q = match S.find_message d.schema q with Some m -> m.S.kind | None -> fail "Descriptor" "Unknown reference"
let rec check d ty value = match ty, value with
  | S.Primitive S.Bool, `Bool _ | S.Primitive S.Int, `Int _
  | S.Primitive S.Float, (`Float _ | `Int _) | S.Primitive S.String, `String _
  | S.Primitive S.Date, `String _ | S.Primitive S.Void, `Null
  | S.Primitive S.Record, `Assoc _ -> ()
  | S.Optional _, `Null -> ()
  | S.Optional t, v -> check d t v
  | S.List t, `List xs -> List.iter (check d t) xs
  | S.Reference q, `List xs -> (match message_kind d q with
    | S.Struct fs ->
      if List.length fs <> List.length xs then fail "Contract" "Invalid structure arity";
      List.iter2 (fun (f : S.field) v -> check d f.type_ v) fs xs
    | S.Variant cs -> (match xs with
      | `String tag :: payload ->
        let c = match List.find_opt (fun (c : S.constructor) -> c.name=tag) cs with Some c -> c | None -> fail "Contract" "Unknown constructor" in
        (match c.payload,payload with S.Primitive S.Void, [] -> () | t,[v] -> check d t v | _ -> fail "Contract" "Invalid variant payload")
      | _ -> fail "Contract" "Invalid variant"))
  | _ -> fail "Contract" "Value violates its message descriptor"
let validate (m : Message.t) =
  let d = descriptor m.type' in
  check d d.ty (json m.drut);
  let validator = synchronized (fun () -> Hashtbl.find_opt validators (key m.type')) in
  Option.iter (fun f -> f m.drut) validator
let accepts expected (m : Message.t) =
  if expected <> any && expected <> m.type' then fail "Contract" "Message type or schema mismatch";
  validate m
module type Codec = sig
  type t
  val to_drut : t -> (string, Cyrograf.Error.t) result
  val from_drut : string -> (t, Cyrograf.Error.t) result
end
let codec (type a) ~schema ~name (module C : Codec with type t=a) =
  let q = match String.split_on_char '.' name with
    | [module_name;message_name] -> S.{module_name;message_name}
    | _ -> fail "Schema" "Use a qualified Cyrograf message name" in
  let type_ = register_descriptor schema (S.Reference q) in
  synchronized (fun () -> Hashtbl.replace validators (key type_) (fun s -> ignore (unwrap (C.from_drut s))));
  { type_; encode=(fun value -> Message.make ~type':type_ ~drut:(unwrap (C.to_drut value)) ());
    decode=(fun m -> accepts type_ m; unwrap (C.from_drut m.drut)) }
let primitive p encode decode =
  let type_ = register_descriptor S.{modules=[]} (S.Primitive p) in
  let decode_text s = unwrap (Result.bind (Kom_contracts.Drut_runtime.of_string s) decode) in
  synchronized (fun () -> Hashtbl.replace validators (key type_) (fun s -> ignore (decode_text s)));
  {type_; encode=(fun v -> Message.make ~type':type_ ~drut:(Kom_contracts.Drut_runtime.to_string (unwrap (encode v))) ());
   decode=(fun m -> accepts type_ m; decode_text m.drut)}
let bool = primitive S.Bool Kom_contracts.Drut_runtime.enc_bool Kom_contracts.Drut_runtime.dec_bool
let int = primitive S.Int Kom_contracts.Drut_runtime.enc_int Kom_contracts.Drut_runtime.dec_int
let string = primitive S.String Kom_contracts.Drut_runtime.enc_string Kom_contracts.Drut_runtime.dec_string
let rec field d ty path value = match path with
  | [] -> ty,value
  | name :: rest -> (match ty, value with
    | S.Reference q, v -> (match message_kind d q, v with
      | S.Struct fs, `List xs ->
        let rec find fs xs = match fs,xs with
          | (f : S.field)::fs,v::xs -> if f.name=name then field d f.type_ rest v else find fs xs
          | _ -> fail "Binding" ("Unknown field: " ^ name) in find fs xs
      | S.Variant cs, `List [`String tag;payload] when name="payload" ->
        let c = List.find (fun (c : S.constructor) -> c.name=tag) cs in field d c.payload rest payload
      | _ -> fail "Binding" "Field source is not a structure")
    | _ -> fail "Binding" "Field source is not a structure")
let rec field_type ?constructors d ty = function
  | [] -> ty
  | name :: rest -> (match ty with
    | S.Reference q -> (match message_kind d q with
      | S.Struct fs -> let f = match List.find_opt (fun (f : S.field) -> f.name=name) fs with
          | Some f -> f | None -> fail "Binding" ("Unknown field: " ^ name) in field_type ?constructors d f.type_ rest
      | S.Variant cs when name="payload" ->
        let cs=match constructors with None -> cs | Some tags -> List.filter (fun (c : S.constructor) -> List.mem c.name tags) cs in
        let ts=List.map (fun (c : S.constructor) -> c.payload) cs |> List.sort_uniq compare in
        (match ts with [t] -> field_type d t rest | _ -> fail "Binding" "Variant payload types are ambiguous")
      | _ -> fail "Binding" "Field type is not a structure")
    | _ -> fail "Binding" "Field type is not a structure")
let project_type ?constructors t path = let d = descriptor t in register_descriptor d.schema (field_type ?constructors d d.ty path)
let project (m : Message.t) path =
  validate m; let d=descriptor m.type' in
  let ty,v=field d d.ty path (json m.drut) in
  Message.make ~type':(register_descriptor d.schema ty) ~drut:(text v) ()
let fields t = let d=descriptor t in match d.ty with
  | S.Reference q -> (match message_kind d q with S.Struct fs -> fs | _ -> fail "Binding" "Fields target must be a structure")
  | _ -> fail "Binding" "Fields target must be a structure"
let construct t bindings =
  let d=descriptor t in
  let rec build ty path =
    match List.assoc_opt path bindings with
    | Some m -> accepts (register_descriptor d.schema ty) m; json m.Message.drut
    | None -> (match ty with
      | S.Optional _ -> `Null
      | S.Reference q -> (match message_kind d q with
        | S.Struct fs -> `List (List.map (fun (f : S.field) -> build f.type_ (path @ [f.name])) fs)
        | _ -> fail "Binding" "Missing variant field")
      | _ -> fail "Binding" "Missing required field") in
  let m = Message.make ~type':t ~drut:(text (build d.ty [])) () in validate m; m
let patterns t = let d=descriptor t in match d.ty with
  | S.Primitive S.Bool -> [OutputPattern.BoolValue true; BoolValue false]
  | S.Reference q -> (match message_kind d q with
    | S.Variant cs -> List.map (fun (c : S.constructor) -> OutputPattern.Constructor (ConstructorPattern.make ~type':t ~tag:c.name ())) cs
    | _ -> fail "Branch" "Source is not Bool or a variant")
  | _ -> fail "Branch" "Source is not Bool or a variant"
let matches pattern (m : Message.t) = match pattern,json m.drut with
  | OutputPattern.BoolValue b, `Bool value -> b=value
  | Constructor c, `List (`String tag :: _) -> c.type'=m.type' && c.tag=tag
  | _ -> false
let constructor codec tag =
  let p=OutputPattern.Constructor (ConstructorPattern.make ~type':codec.type_ ~tag ()) in
  if not (List.mem p (patterns codec.type_)) then fail "Branch" "Unknown constructor"; p
