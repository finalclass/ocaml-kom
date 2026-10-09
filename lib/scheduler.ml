type t = { mutex:Mutex.t; changed:Condition.t; capacity:int; mutable active:int; mutable tasks:int }
let create capacity =
  if capacity < 1 then invalid_arg "workers must be positive";
  {mutex=Mutex.create ();changed=Condition.create ();capacity;active=0;tasks=0}
let permit = Domain.DLS.new_key (fun () -> None)
let acquire_capacity t =
  Mutex.lock t.mutex;
  while t.active >= t.capacity do Condition.wait t.changed t.mutex done;
  t.active <- t.active+1; Mutex.unlock t.mutex
let acquire t = acquire_capacity t; Domain.DLS.set permit (Some t)
let release t =
  if Option.is_some (Domain.DLS.get permit) then (
    Domain.DLS.set permit None;
    Mutex.lock t.mutex; t.active <- t.active-1;
    Condition.broadcast t.changed; Mutex.unlock t.mutex)
let suspend t f =
  let held=match Domain.DLS.get permit with Some owner -> owner == t | None -> false in
  if held then release t;
  Fun.protect f ~finally:(fun () -> if held then acquire t)
let submit t f =
  Mutex.lock t.mutex; t.tasks <- t.tasks+1; Mutex.unlock t.mutex;
  ignore (Thread.create (fun () ->
    acquire_capacity t;
    let domain=Domain.spawn (fun () -> Domain.DLS.set permit (Some t);
      Fun.protect f ~finally:(fun () -> release t)) in
    Fun.protect (fun () -> Domain.join domain) ~finally:(fun () ->
      Mutex.lock t.mutex; t.tasks <- t.tasks-1;
      Condition.broadcast t.changed; Mutex.unlock t.mutex)) ())
let drain t =
  Mutex.lock t.mutex;
  while t.tasks > 0 do Condition.wait t.changed t.mutex done;
  Mutex.unlock t.mutex
