open Native_contract
let mutex=Mutex.create ()
let changed=Condition.create ()
type child_slot = Creating | Ready of system | Failed of exn
let children:(string,child_slot) Hashtbl.t=Hashtbl.create 16
let factory : (scheduler:Scheduler.t -> storage:storage -> id:string -> definition -> system) option ref = ref None
let set_factory f = factory := Some f
let child ~scheduler ~storage ~owner ~cell_id ~id definition =
  let key=Yojson.Safe.to_string (`List [`String owner;`String cell_id;`String id]) in
  Mutex.lock mutex;
  let rec lookup () = match Hashtbl.find_opt children key with
    | Some (Ready s) -> Mutex.unlock mutex; s
    | Some (Failed exn) -> Mutex.unlock mutex; raise exn
    | Some Creating -> Condition.wait changed mutex; lookup ()
    | None ->
      Hashtbl.add children key Creating; Mutex.unlock mutex;
      try
        let f=match !factory with Some f -> f | None -> failwith "Kom hosting is not initialized" in
        let s=f ~scheduler ~storage ~id:key definition in
        Mutex.lock mutex; Hashtbl.replace children key (Ready s);
        Condition.broadcast changed; Mutex.unlock mutex; s
      with exn ->
        Mutex.lock mutex; Hashtbl.replace children key (Failed exn);
        Condition.broadcast changed; Mutex.unlock mutex; raise exn in
  lookup ()
let close_children owner =
  Mutex.lock mutex;
  let owned=Hashtbl.fold (fun key slot xs ->
    match Yojson.Safe.from_string key,slot with
    | `List (`String p::_),Ready s when p=owner -> (key,s)::xs | _ -> xs) children [] in
  Mutex.unlock mutex;
  List.iter (fun (key,s) -> s.close (); Mutex.lock mutex;
    Hashtbl.remove children key; Mutex.unlock mutex) owned
let uuid () =
  let ch=open_in_bin "/dev/urandom" in
  let bytes=Fun.protect (fun () -> really_input_string ch 16) ~finally:(fun () -> close_in ch) in
  String.concat "" (List.init 16 (fun i -> Printf.sprintf "%02x" (Char.code bytes.[i])))
