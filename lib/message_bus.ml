type t = { mutex:Mutex.t; mutable work:(unit -> unit) option; mutable admission:(unit -> unit) option }
let create () = {mutex=Mutex.create ();work=None;admission=None}
let register t ~work ~admission = Mutex.lock t.mutex; t.work <- Some work; t.admission <- Some admission; Mutex.unlock t.mutex
let deliver t admission =
  Mutex.lock t.mutex; let f=if admission then t.admission else t.work in Mutex.unlock t.mutex;
  Option.iter (fun f -> f ()) f
let work t = deliver t false
let admission t = deliver t true
