type 'a promise = {
  mutex : Mutex.t; changed : Condition.t;
  mutable result : ('a, exn) result option;
}
type t = {
  mutex : Mutex.t; changed : Condition.t; queue : (unit -> unit) Queue.t;
  capacity : int; mutable closing : bool; mutable domains : unit Domain.t list;
}
let locked mutex f =
  Mutex.lock mutex; Fun.protect f ~finally:(fun () -> Mutex.unlock mutex)
let create capacity =
  if capacity < 1 then invalid_arg "workers must be positive";
  let t = {mutex = Mutex.create (); changed = Condition.create (); queue = Queue.create ();
    capacity; closing = false; domains = []} in
  let rec worker () =
    let job = locked t.mutex (fun () ->
      while Queue.is_empty t.queue && not t.closing do Condition.wait t.changed t.mutex done;
      if Queue.is_empty t.queue then None else Some (Queue.pop t.queue)) in
    match job with None -> () | Some job -> job (); worker ()
  in
  (try
     for _ = 1 to capacity do t.domains <- Domain.spawn worker :: t.domains done
   with exn ->
     locked t.mutex (fun () -> t.closing <- true; Condition.broadcast t.changed);
     List.iter Domain.join t.domains; raise exn);
  t
let submit t f =
  let promise = {mutex = Mutex.create (); changed = Condition.create (); result = None} in
  locked t.mutex (fun () ->
    if t.closing then invalid_arg "Scheduler is closed";
    Queue.push (fun () ->
      let result = try Ok (f ()) with exn -> Result.Error exn in
      locked promise.mutex (fun () ->
        promise.result <- Some result; Condition.broadcast promise.changed)) t.queue;
    Condition.signal t.changed);
  promise
let await (promise : 'a promise) =
  let result = locked promise.mutex (fun () ->
    while promise.result = None do Condition.wait promise.changed promise.mutex done;
    Option.get promise.result) in
  match result with Ok result -> result | Result.Error exn -> raise exn
let close t =
  locked t.mutex (fun () -> t.closing <- true; Condition.broadcast t.changed);
  List.iter Domain.join t.domains
