open Example_cells.Model
module T=Kom.Types
module Gate=struct
  type t={mutex:Mutex.t;changed:Condition.t;mutable arrived:int;mutable opened:bool}
  let create ()={mutex=Mutex.create ();changed=Condition.create ();arrived=0;opened=false}
  let arrive t=Mutex.lock t.mutex;t.arrived<-t.arrived+1;Condition.broadcast t.changed;Mutex.unlock t.mutex
  let wait t=Mutex.lock t.mutex;while not t.opened do Condition.wait t.changed t.mutex done;Mutex.unlock t.mutex
  let enter t=arrive t;wait t
  let count t=Mutex.lock t.mutex;let n=t.arrived in Mutex.unlock t.mutex;n
  let wait_count t n=Mutex.lock t.mutex;while t.arrived<n do Condition.wait t.changed t.mutex done;Mutex.unlock t.mutex
  let open_ t=Mutex.lock t.mutex;t.opened<-true;Condition.broadcast t.changed;Mutex.unlock t.mutex
end
let check condition message=if not condition then failwith message
let ints ms=List.map decode ms
let equal expected actual=check (expected=actual) "Unexpected result"
let receipt=function T.SendResponse.Admitted r | Buffered r -> r | Rejected p -> raise (Kom.Error p)
let await system r=match Kom.System.await system r with
  | T.AwaitResponse.Finished c -> completed c | UnknownReceipt -> failwith "Unknown receipt"
let expect_rejected system flow input=match Kom.System.send system ~flow:(Kom.Flow.inline flow) input with
  | T.SendResponse.Rejected _ -> () | _ -> failwith "Expected rejection"
let named_use as_ flow=Kom.Flow.use ~as_ flow
let test_sequence ()=
  let c=counter ~id:"c" () in
  with_system (definition [Kom.Cell.spec ~id:"c" c]) (fun s ->
    let flow=Kom.Flow.sequence [step ~id:"first" "c"; step ~id:"second" ~input:(Kom.Flow.bind (Kom.Flow.output "first")) "c"] in
    equal [6] (call s (Kom.Flow.inline flow) 3 |> ints);
    equal [7] (call s (Kom.Flow.inline (step "c")) 1 |> ints);
    expect_rejected s (Kom.Flow.sequence [step ~id:"same" "c";step ~id:"same" "c"]) (amount 1);
    expect_rejected s (step ~input:(Kom.Flow.bind (Kom.Flow.output "missing")) "c") (amount 1);
    ignore (get (Kom.Cell.instantiate s ~id:"extra" (counter ~id:"extra" ())));
    equal [2] (call s (Kom.Flow.inline (step "extra")) 2 |> ints);
    check (Result.is_error (Kom.Cell.instantiate s ~id:"c" c)) "Duplicate instantiation accepted")
let variant_cell counts invalid=
  let module C=struct
    type state=unit
    let id="chooser"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Choose" ~input:value ~outputs:[Kom.Message.type_ decision]]
    let init _ _=Ok ()
    let handle _ () ~operation:_ m=
      Atomic.incr counts;
      let n=decode m in
      let d=if n>0 then D.Decision.Accepted (D.Amount.make ~amount:n ())
        else if n<0 then Rejected (D.Amount.make ~amount:n ()) else Review (D.Amount.make ~amount:99 ()) in
      let message=if invalid then amount n else Kom.Message.encode decision d in
      Ok ((),Kom.Message.batch [message])
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in Kom.Cell.define (module C)
let test_routing ()=
  let calls=Atomic.make 0 and a=Atomic.make 0 and b=Atomic.make 0 and d=Atomic.make 0 in
  let def=definition [Kom.Cell.spec ~id:"check" (variant_cell calls false);
    Kom.Cell.spec ~id:"a" (counter ~id:"a" ~on_handle:(fun _ -> Atomic.incr a) ());
    Kom.Cell.spec ~id:"b" (counter ~id:"b" ~on_handle:(fun _ -> Atomic.incr b) ());
    Kom.Cell.spec ~id:"d" (counter ~id:"d" ~on_handle:(fun _ -> Atomic.incr d) ())] in
  let choose=Kom.Flow.step ~id:"choose" ~cell:"check" ~operation:"Choose" () in
  let run cell=step ~id:cell ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"choose" ["payload"])) cell in
  let accepted=Kom.Flow.constructor decision ~tag:"Accepted" in
  let rejected=Kom.Flow.constructor decision ~tag:"Rejected" in
  let cases=[Kom.Flow.case ~output:accepted (run "a");Kom.Flow.case ~output:rejected (run "b")] in
  let flow=Kom.Flow.sequence [choose;Kom.Flow.branch ~from:(Kom.Flow.output "choose") ~default:(run "d") cases] in
  with_system def (fun s ->
    equal [5] (call s (Kom.Flow.inline flow) 5 |> ints);
    equal [-3] (call s (Kom.Flow.inline flow) (-3) |> ints);
    equal [99] (call s (Kom.Flow.inline flow) 0 |> ints);
    equal [1;1;1;3] [Atomic.get a;Atomic.get b;Atomic.get d;Atomic.get calls];
    expect_rejected s (Kom.Flow.sequence [choose;Kom.Flow.branch ~from:(Kom.Flow.output "choose") cases]) (amount 1);
    let repeated=[Kom.Flow.case ~output:accepted (run "a");Kom.Flow.case ~output:accepted (run "b")] in
    expect_rejected s (Kom.Flow.sequence [choose;Kom.Flow.branch ~from:(Kom.Flow.output "choose") ~default:(run "d") repeated]) (amount 1);
    let impossible=T.OutputPattern.Constructor (T.ConstructorPattern.make ~type':(Kom.Message.type_ decision) ~tag:"Absent" ()) in
    expect_rejected s (Kom.Flow.sequence [choose;Kom.Flow.branch ~from:(Kom.Flow.output "choose") ~default:(run "d") [Kom.Flow.case ~output:impossible (run "a")]]) (amount 1));
  let bad=definition [Kom.Cell.spec ~id:"check" (variant_cell (Atomic.make 0) true);
    Kom.Cell.spec ~id:"d" (counter ~id:"d" ~on_handle:(fun _ -> Atomic.incr d) ())] in
  with_system bad (fun s ->
    let flow=Kom.Flow.sequence [choose;Kom.Flow.branch ~from:(Kom.Flow.output "choose") ~default:(run "d") []] in
    match Kom.System.call s ~flow:(Kom.Flow.inline flow) (amount 1) |> get with
    | T.Completion.Failed p -> check (p.code="Contract" && Atomic.get d=1) "Default hid a cell contract violation"
    | _ -> failwith "Invalid output succeeded")
let test_bool_and_fields ()=
  let module C=struct
    type state=unit
    let id="bool"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Check" ~input:condition ~outputs:[Kom.Message.type_ condition];
      Kom.Operation.make ~name:"Pair" ~input:pair ~outputs:[Kom.Message.type_ value]]
    let init _ _=Ok ()
    let handle _ () ~operation m=if operation="Check" then Ok ((),Kom.Message.batch [m]) else
      let p=Kom.Message.decode pair m in Ok ((),Kom.Message.batch [amount (p.left+p.right)])
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in
  let def=definition [Kom.Cell.spec ~id:"bool" (Kom.Cell.define (module C));
    Kom.Cell.spec ~id:"a" (counter ~id:"a" ());Kom.Cell.spec ~id:"b" (counter ~id:"b" ())] in
  with_system def (fun s ->
    let flow=Kom.Flow.sequence [Kom.Flow.step ~id:"check" ~cell:"bool" ~operation:"Check" ();
      Kom.Flow.branch ~from:(Kom.Flow.field ~from:"check" ["value"]) [
        Kom.Flow.case ~output:(Kom.Flow.bool true) (step "a" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:10 ()))));
        Kom.Flow.case ~output:(Kom.Flow.bool false) (step "b" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:20 ()))))]] in
    List.iter (fun (flag,want) ->
      let input=Kom.Message.encode condition (D.Condition.make ~value:flag ()) in
      equal [want] (Kom.System.call s ~flow:(Kom.Flow.inline flow) input |> get |> completed |> ints)) [true,10;false,20];
    let input=Kom.Flow.input_type value (Kom.Flow.step ~cell:"bool" ~operation:"Pair"
      ~input:(Kom.Flow.bind_fields [["left"],Kom.Flow.field ["amount"];["right"],Kom.Flow.constant Kom.Message.int 7]) ()) in
    equal [10] (call s (Kom.Flow.inline input) 3 |> ints);
    let missing=Kom.Flow.input_type value (Kom.Flow.step ~cell:"bool" ~operation:"Pair"
      ~input:(Kom.Flow.bind_fields [["left"],Kom.Flow.field ["amount"]]) ()) in
    expect_rejected s missing (amount 1))
let test_use ()=
  let count=Atomic.make 0 in
  let prepare=fragment () in
  let wrapped=Kom.Flow.define ~id:"wrapped" (Kom.Flow.use ~as_:"inner/with:separator" prepare) in
  let flow=Kom.Flow.parallel [Kom.Flow.sequence [named_use "one" wrapped;named_use "two" prepare]; named_use "one:parallel" wrapped] in
  let cells=List.map (fun id -> Kom.Cell.spec ~id (counter ~id ~on_handle:(fun _ -> Atomic.incr count) ())) ["a";"b";"c"] in
  with_system (definition ~flows:[prepare;wrapped] cells) (fun s ->
    let ms=call s (Kom.Flow.inline flow) 1 in
    check (List.length ms=2 && Atomic.get count=9) "Use duplicated instances or lost work";
    let bound=Kom.Flow.sequence [named_use "first" prepare;
      step ~id:"last" ~input:(Kom.Flow.bind (Kom.Flow.output "first")) "a"] in
    check (List.length (call s (Kom.Flow.inline bound) 1)=1) "Use output unavailable";
    expect_rejected s (named_use "unknown" (Kom.Flow.define ~id:"absent" (step "a"))) (amount 1);
    let wrong=Kom.Flow.use ~as_:"bad" ~input:(Kom.Flow.bind (Kom.Flow.constant Kom.Message.bool true)) prepare in
    expect_rejected s wrong (amount 1));
  let stub name=Kom.Flow.define ~id:name (Kom.Flow.sequence []) in
  let cyclic_a=Kom.Flow.define ~id:"A" (named_use "b" (stub "B")) in
  let cyclic_b=Kom.Flow.define ~id:"B" (named_use "a" (stub "A")) in
  check (Result.is_error (Kom.System.create (definition ~flows:[cyclic_a;cyclic_b] cells))) "Flow cycle accepted"
let test_use_branch ()=
  let choose=Kom.Flow.define ~id:"choose" (Kom.Flow.step ~id:"step" ~cell:"check" ~operation:"Choose" ()) in
  let flow=Kom.Flow.sequence [named_use "decision" choose;
    Kom.Flow.branch ~from:(Kom.Flow.output "decision")
      ~default:(step ~id:"default" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"decision" ["payload"])) "c")
      [Kom.Flow.case ~output:(Kom.Flow.constructor decision ~tag:"Accepted")
        (step ~id:"accepted" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"decision" ["payload"])) "c")]] in
  let def=definition ~flows:[choose] [Kom.Cell.spec ~id:"check" (variant_cell (Atomic.make 0) false);Kom.Cell.spec ~id:"c" (counter ~id:"c" ())] in
  with_system def (fun s -> equal [6] (call s (Kom.Flow.inline flow) 6 |> ints))
let test_exclusivity ()=
  let gate=Gate.create () in
  let c=counter ~id:"busy" ~on_handle:(fun _ -> Gate.enter gate) () in
  let def=definition [Kom.Cell.spec ~id:"busy" c;Kom.Cell.spec ~id:"free" (counter ~id:"free" ())] in
  with_system ~workers:2 def (fun s ->
    let first=Kom.System.send s ~flow:(Kom.Flow.inline (step "busy")) (amount 1) |> receipt in
    Gate.wait_count gate 1;
    let second=Kom.System.send s ~flow:(Kom.Flow.inline (step "busy")) (amount 2) |> receipt in
    equal [4] (call s (Kom.Flow.inline (step "free")) 4 |> ints);
    equal [1] [Gate.count gate];
    Gate.open_ gate;
    equal [1] (await s first |> ints);equal [3] (await s second |> ints))
let memory_observer ()=
  let latest=ref None and changed=Gate.create () in
  let mutex=Mutex.create () in
  let storage=Kom.Storage.backend (fun _ -> Kom.Storage.{load=(fun () -> None);close=(fun () -> ());
    save=(fun data ->
      let snap=Kom__Message_codec.unwrap (Kom_contracts.Execution_access.StoreSnapshot.from_drut data) in
      Mutex.lock mutex;latest:=Some snap;Mutex.unlock mutex;
      if List.exists (fun (e : Kom_contracts.Execution_access.StoredExecution.t) ->
        match e.checkpoint with Some cp -> cp.version>0 | None -> false) snap.executions then Gate.arrive changed)}) in
  storage,changed,(fun () -> Mutex.lock mutex;let s = !latest in Mutex.unlock mutex;Option.get s)
let test_parallel_conflict ()=
  let a=Gate.create () and b=Gate.create () in
  let calls=Atomic.make 0 in
  let counter_for id gate=counter ~id ~on_handle:(fun _ -> Atomic.incr calls;Gate.enter gate) () in
  let def=definition [Kom.Cell.spec ~id:"a" (counter_for "a" a);Kom.Cell.spec ~id:"b" (counter_for "b" b)] in
  let storage,committed,snapshot=memory_observer () in
  get (Kom.System.with_ ~workers:2 ~storage def (fun s ->
    let flow=Kom.Flow.parallel [step "a" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:1 ())));
      step "b" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:2 ())))] in
    let r=Kom.System.send s ~flow:(Kom.Flow.inline flow) (amount 0) |> receipt in
    Gate.wait_count a 1;Gate.wait_count b 1;
    Gate.open_ b;Gate.wait_count committed 1;
    check (List.exists (fun (e : Kom_contracts.Execution_access.StoredExecution.t) -> e.completion=None) (snapshot ()).executions) "One parallel branch completed the flow";
    Gate.open_ a;equal [1;2] (await s r |> ints);equal [2] [Atomic.get calls]))
let test_update ()=
  let gate=Gate.create () and migration=Gate.create () in
  let c1=counter ~id:"c" ~on_handle:(fun _ -> Gate.enter gate) () in
  let c2=counter ~id:"c" ~revision:"2" ~state_version:2 ~restore:(fun old -> if old.state_version=1 then (Gate.enter migration;Kom.Cell.Restored (int_of_string old.data+100)) else Kom.Cell.Restored (int_of_string old.data)) () in
  let f1=Kom.Flow.define ~id:"flow" (step "c") in
  let f2=Kom.Flow.define ~id:"flow" ~version:2 (step "c") in
  let old=definition ~flows:[f1] [Kom.Cell.spec ~id:"c" c1] in
  let next=definition ~flows:[f2] [Kom.Cell.spec ~id:"c" c2] in
  with_system old (fun s ->
    let first=Kom.System.send s ~flow:(Kom.Flow.named "flow") (amount 1) |> receipt in
    Gate.wait_count gate 1;
    let update_result=ref None in
    let thread=Thread.create (fun () -> update_result:=Some (Kom.System.update ~force:true s next)) () in
    (* Reaching migration proves the old execution drained and the gate is shut. *)
    Gate.open_ gate;Gate.wait_count migration 1;
    let buffered=Kom.System.send s ~flow:(Kom.Flow.named "flow") (amount 2) in
    let r=match buffered with T.SendResponse.Buffered r -> r | _ -> failwith "Update did not buffer entry" in
    Gate.open_ migration;Thread.join thread;ignore (get (Option.get !update_result));
    equal [1] (await s first |> ints);equal [103] (await s r |> ints);
    let failed=counter ~id:"c" ~revision:"failed" ~restore:(fun _ -> Kom.Cell.Failed (T.Problem.make ~code:"Migration" ~message:"failed" ())) () in
    check (Result.is_error (Kom.System.update ~force:true s (definition ~flows:[f2] [Kom.Cell.spec ~id:"c" failed]))) "Force hid Failed";
    equal [104] (call s (Kom.Flow.named "flow") 1 |> ints);
    let throws=counter ~id:"c" ~revision:"throws" ~restore:(fun _ -> failwith "restore failed") () in
    check (Result.is_error (Kom.System.update ~force:true s (definition ~flows:[f2] [Kom.Cell.spec ~id:"c" throws]))) "Force hid exception";
    equal [105] (call s (Kom.Flow.named "flow") 1 |> ints))
let test_force ()=
  let old=counter ~id:"old" () in
  let success=counter ~id:"old" ~revision:"2" ~state_version:4 ~restore:(fun s -> Kom.Cell.Restored (int_of_string s.data+(if s.state_version=4 then 0 else 10))) () in
  let unsupported=counter ~id:"other" ~revision:"2" ~state_version:2 ~init:50 ~restore:(fun s -> if s.state_version=2 then Kom.Cell.Restored (int_of_string s.data) else Kom.Cell.Unsupported (T.Problem.make ~code:"Unsupported" ~message:"no migration" ())) () in
  with_system (definition [Kom.Cell.spec ~id:"a" old;Kom.Cell.spec ~id:"b" (counter ~id:"other" ())]) (fun s ->
    ignore (call s (Kom.Flow.inline (step "a")) 2);
    let next=definition [Kom.Cell.spec ~id:"a" success;Kom.Cell.spec ~id:"b" unsupported] in
    check (Result.is_error (Kom.System.update s next)) "Unsupported migrated without Force";
    equal [3] (call s (Kom.Flow.inline (step "a")) 1 |> ints);
    ignore (get (Kom.System.update ~force:true s next));
    equal [14] (call s (Kom.Flow.inline (step "a")) 1 |> ints);
    (* Only the unsupported migration is reset. *)
    let fixed=counter ~id:"other" ~revision:"3" ~state_version:2 () in
    ignore (get (Kom.System.update s (definition [Kom.Cell.spec ~id:"a" success;Kom.Cell.spec ~id:"b" fixed])));
    equal [51] (call s (Kom.Flow.inline (step "b")) 1 |> ints))
let test_child_retry ()=
  let calls=Atomic.make 0 and parent_calls=Atomic.make 0 in
  let child_def=child_definition (counter ~id:"child" ~on_handle:(fun _ -> Atomic.incr calls) ()) in
  let module P=struct
    type state=unit
    let id="parent"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Run" ~input:value ~outputs:[Kom.Message.type_ value]]
    let init _ _=Ok ()
    let handle ctx () ~operation:_ m=
      let child=Kom.Context.child ctx ~id:"child" child_def in
      let flow=Kom.Flow.inline (step ~id:"child-step" "child") in
      let result=Kom.Context.call ctx ~call_id:"one" child ~flow m in
      if Atomic.fetch_and_add parent_calls 1=0 then Error (T.Problem.make ~code:"Transient" ~message:"retry" ())
      else Ok ((),Kom.Message.batch (completed result))
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in
  with_system ~workers:1 ~max_attempts:2 (definition [Kom.Cell.spec ~id:"p" (Kom.Cell.define (module P))]) (fun s ->
    equal [9] (call s (Kom.Flow.inline (Kom.Flow.step ~cell:"p" ~operation:"Run" ())) 9 |> ints);
    equal [1;2] [Atomic.get calls;Atomic.get parent_calls])
let test_sqlite_atomicity ()=
  let path=Filename.temp_file "kom-atomic-" ".sqlite" in
  let fail_once=Atomic.make false and effects=Atomic.make 0 and gate=Gate.create () in
  let storage=Kom_sqlite.storage ~before_commit:(fun () ->
    if Atomic.exchange fail_once false then failwith "injected SQLite rollback") path in
  let module Mutable=struct
    type state=int ref
    let id="mutable"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Add" ~input:value ~outputs:[Kom.Message.type_ value]]
    let init _ _=Ok (ref 0)
    let handle _ state ~operation:_ message=
      Atomic.incr effects;Gate.enter gate;
      state := !state + decode message;
      Ok (state,Kom.Message.batch [amount !state])
    let snapshot state=Ok (string_of_int !state)
    let restore _ _ (s : T.StateSnapshot.t)=Kom.Cell.Restored (ref (int_of_string s.data))
    let release _=()
  end in
  let c=Kom.Cell.define (module Mutable) in
  let def=definition [Kom.Cell.spec ~id:"c" c] in
  get (Kom.System.with_ ~storage ~max_attempts:2 def (fun s ->
    let r=Kom.System.send s ~flow:(Kom.Flow.inline (step "c")) (amount 5) |> receipt in
    Gate.wait_count gate 1;Atomic.set fail_once true;Gate.open_ gate;
    equal [5] (await s r |> ints);equal [2] [Atomic.get effects];
    equal [6] (call s (Kom.Flow.inline (step "c")) 1 |> ints)));
  List.iter (fun suffix -> let file=path^suffix in if Sys.file_exists file then Sys.remove file) ["";"-wal";"-shm"]
let test_scopes ()=
  let opened=Atomic.make 0 and closed=Atomic.make 0 in
  let module R=struct
    type state={mutable amount:int;alive:bool ref}
    let id="resource"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Add" ~input:value ~outputs:[Kom.Message.type_ value]]
    let make amount=Atomic.incr opened;{amount;alive=ref true}
    let init _ _=Ok (make 0)
    let handle _ s ~operation:_ m=s.amount<-s.amount+decode m;Ok (s,Kom.Message.batch [amount s.amount])
    let snapshot s=Ok (string_of_int s.amount)
    let restore _ _ (s : T.StateSnapshot.t)=Kom.Cell.Restored (make (int_of_string s.data))
    let release s=if !(s.alive) then (s.alive:=false;Atomic.incr closed)
  end in
  let child=child_definition (Kom.Cell.define (module R)) in
  let def=definition [Kom.Cell.spec ~id:"p" (parent child)] in
  (try ignore (Kom.System.with_ ~workers:1 def (fun s ->
    equal [1] (call s (Kom.Flow.inline (Kom.Flow.step ~cell:"p" ~operation:"Run" ())) 1 |> ints);
    failwith "user exception")) with Failure _ -> ());
  equal [Atomic.get opened] [Atomic.get closed]
let spawn mode path =
  let input_read,input_write=Unix.pipe () and output_read,output_write=Unix.pipe () in
  let exe=Filename.concat (Sys.getcwd ()) "crash_worker.exe" in
  let pid=Unix.create_process exe [|exe;mode;path|] input_read output_write Unix.stderr in
  Unix.close input_read;Unix.close output_write;
  pid,Unix.in_channel_of_descr output_read,Unix.out_channel_of_descr input_write
let test_recovery mode =
  let path=Filename.temp_file "kom-recovery-" ".sqlite" in
  let pid,output,input=spawn (mode^"-seed") path in
  let receipt_text=input_line output in
  equal ["READY"] [input_line output];
  Unix.kill pid Sys.sigkill;ignore (Unix.waitpid [] pid);close_in output;close_out_noerr input;
  let pid,output,input=spawn (mode^"-resume") path in
  output_string input (receipt_text^"\n");flush input;
  equal ["RESULT 1"] [input_line output];
  check (Unix.waitpid [] pid |> snd = Unix.WEXITED 0) "Recovery worker failed";
  close_in output;close_out_noerr input;
  List.iter (fun suffix -> let file=path^suffix in if Sys.file_exists file then Sys.remove file) ["";"-wal";"-shm"]

let test_buffer_rejection ()=
  let migration=Gate.create () in
  let c1=counter ~id:"c" () in
  let c2=counter ~id:"c" ~revision:"2" ~restore:(fun s -> Gate.enter migration;Kom.Cell.Restored (int_of_string s.data)) () in
  let old=definition ~flows:[Kom.Flow.define ~id:"removed" (step "c")] [Kom.Cell.spec ~id:"c" c1] in
  let next=definition [Kom.Cell.spec ~id:"c" c2] in
  with_system old (fun s ->
    let update_result=ref None in
    let thread=Thread.create (fun () -> update_result:=Some (Kom.System.update s next)) () in
    Gate.wait_count migration 1;
    let r=match Kom.System.send s ~flow:(Kom.Flow.named "removed") (amount 1) with
      | T.SendResponse.Buffered r -> r | _ -> failwith "Expected Buffered" in
    Gate.open_ migration;Thread.join thread;ignore (get (Option.get !update_result));
    match Kom.System.await s r with
    | T.AwaitResponse.Finished (T.Completion.Failed p) -> check (p.code="Flow") "Wrong buffer rejection"
    | _ -> failwith "Rejected buffered receipt was not resolved")
let test_force_contract ()=
  let module Bad=struct
    type state=int
    let id="c"
    let revision="incompatible"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Add" ~input:Kom.Message.bool ~outputs:[Kom.Message.type_ Kom.Message.bool]]
    let init _ _=Ok 0
    let handle _ state ~operation:_ message=Ok (state,Kom.Message.batch [message])
    let snapshot state=Ok (string_of_int state)
    let restore _ _ (s : T.StateSnapshot.t)=Kom.Cell.Restored (int_of_string s.data)
    let release _=()
  end in
  with_system (definition [Kom.Cell.spec ~id:"c" (counter ~id:"c" ())]) (fun s ->
    ignore (call s (Kom.Flow.inline (step "c")) 3);
    check (Result.is_error (Kom.System.update ~force:true s (definition [Kom.Cell.spec ~id:"c" (Kom.Cell.define (module Bad))]))) "Force ignored message compatibility";
    equal [4] (call s (Kom.Flow.inline (step "c")) 1 |> ints))
let direct_store ()=
  let module X=Kom__Execution_access in
  let store=X.create Kom__Native_contract.Memory "direct" in
  let implementation=T.ImplementationRef.make ~id:"counter" ~revision:"1" () in
  let op=Kom.Operation.make ~name:"Add" ~input:value ~outputs:[Kom.Message.type_ value] in
  let desc=T.CellDefinition.make ~implementation ~state_version:1 ~operations:[op] () in
  let spec=T.CellSpec.make ~id:"c" ~implementation ~configuration:(`Assoc []) () in
  let flows=Kom__Flow_access.create () in let catalog=Kom__Flow_access.stage flows [] in
  let prepared=T.PreparedState.make ~value:(T.StateRef.make ~id:"initial" ()) ~snapshot:(T.StateSnapshot.make ~state_version:1 ~data:"0" ()) () in
  let revision=T.PreparedRevision.make ~revision:"1" ~definition:(T.SystemDefinition.make ~cells:[spec] ~flows:[] ())
    ~code:(T.CodeStage.make ~id:"code" ~definitions:[desc] ()) ~catalog
    ~cells:[T.PreparedCell.make ~cell_id:"c" ~implementation ~state:prepared ()] () in
  let basis=T.ActivationBasis.New (T.NewSystem.make ~system:(T.SystemRef.make ~id:"direct" ()) ~configuration:(T.SystemConfiguration.make ~storage:T.Storage.Memory ()) ()) in
  ignore (X.activate store basis revision);store,flows,catalog
let test_commit_identity_and_close ()=
  let module X=Kom__Execution_access in let module A=Kom_contracts.Execution_access in
  let store,flows,catalog=direct_store () in
  let view=X.view store in
  let flow=Kom__Flow_engine.validate ~catalog ~flows ~system:view (Kom.Flow.sequence [step ~id:"first" "c";step ~id:"second" "c"]) in
  let plan=Kom__Flow_engine.start flow (amount 1) in
  let entry=T.Entry.make ~id:"entry" ~system:view.system ~flow:(Kom.Flow.inline flow.definition) ~message:(amount 1) () in
  let request=A.AdmitRequest.make ~entry ~expected_revision:view.revision ~decision:(A.AdmissionDecision.Planned plan) () in
  let r=match X.admit store request with A.AdmitResponse.Admitted r -> r | _ -> failwith "admit" in
  let wr=T.WorkRef.make ~execution:r.execution ~work_id:(List.hd plan.work).id () in
  let reservation=match X.reserve store wr with A.ReserveResponse.Reserved r -> r | _ -> failwith "reserve" in
  let output=T.StepOutput.make ~work_id:reservation.work.id ~node_id:reservation.work.node_id ~branch_path:reservation.work.branch_path ~messages:(Kom.Message.batch [amount 1]) () in
  let advancement=Kom__Flow_engine.advance flow reservation.progress output in
  let state=T.PreparedState.make ~value:(T.StateRef.make ~id:"next" ()) ~snapshot:(T.StateSnapshot.make ~state_version:1 ~data:"1" ()) () in
  let request=A.CommitRequest.make ~reservation_token:reservation.token ~expected_progress_version:0 ~state ~advancement () in
  let committed=match X.commit store request with A.CommitResponse.Committed c -> c | _ -> failwith "commit" in
  (match X.commit store request with A.CommitResponse.AlreadyCommitted c -> check (c=committed) "Duplicate commit changed response" | _ -> failwith "Duplicate commit was not idempotent");
  check (List.length (X.ready store)=1) "Duplicate commit produced extra work";
  let next=List.hd (X.ready store) in
  let reserved=match X.reserve store next with A.ReserveResponse.Reserved r -> r | _ -> failwith "reserve second" in
  ignore (X.release store reserved.token (T.FailureDecision.Fail (T.Problem.make ~code:"Test" ~message:"complete" ())));
  let q=X.quiesce store T.QuiescencePurpose.Revision in
  let buffered_entry={entry with T.Entry.id="buffered"} in
  let buffered=match X.prepare store buffered_entry with A.PrepareResponse.Buffered r -> r | _ -> failwith "prepare buffer" in
  X.resume store q.quiescence;
  let q=X.quiesce store T.QuiescencePurpose.Closure in
  ignore (X.close store q.quiescence);
  (match X.await store buffered with T.AwaitResponse.Finished (T.Completion.Failed p) -> check (p.code="Closed") "Buffer not closed" | _ -> failwith "Close left pending receipt");
  X.dispose store
let test_pinned_dependencies ()=
  let module F=Kom__Flow_engine in
  let store,flows,_=direct_store () in
  let leaf1=Kom.Flow.define ~id:"leaf" (step ~id:"leaf-step" "c" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:1 ())))) in
  let wrap1=Kom.Flow.define ~id:"wrap" (Kom.Flow.use ~as_:"inner" leaf1) in
  let catalog=Kom__Flow_access.stage flows [leaf1;wrap1] in
  let view={(Kom__Execution_access.view store) with T.SystemView.catalog=catalog} in
  let flow=F.validate ~catalog ~flows ~system:view (Kom.Flow.use ~as_:"outer" wrap1) in
  check (List.length flow.dependencies=2) "Transitive dependency missing";
  let plan=F.start flow (amount 0) in
  let leaf2=Kom.Flow.define ~id:"leaf" ~version:2 (step ~id:"new" "c" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:100 ())))) in
  ignore (Kom__Flow_access.stage flows [leaf2]);Kom__Flow_access.discard flows catalog;
  let work=List.hd plan.work in
  equal [1] [decode work.message];
  let output=T.StepOutput.make ~work_id:work.id ~node_id:work.node_id ~branch_path:work.branch_path ~messages:(Kom.Message.batch [work.message]) () in
  let advanced=F.advance flow plan.progress output in
  equal [1] (Option.get advanced.completion |> completed |> ints);
  Kom__Execution_access.dispose store
let test_narrowing_and_batch ()=
  let calls=Atomic.make 0 in
  let module C=struct
    type state=unit
    let id="mixed"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Choose" ~input:value ~outputs:[Kom.Message.type_ mixed];
      Kom.Operation.make ~name:"Double" ~input:value ~outputs:[Kom.Message.type_ condition]]
    let init _ _=Ok ()
    let handle _ () ~operation message=
      if operation="Double" then (
        let m=Kom.Message.encode condition (D.Condition.make ~value:true ()) in
        Ok ((),Kom.Message.batch [m;m]))
      else
        let n=decode message in
        let m=if n=0 then D.Mixed.Nothing else Payload (D.Amount.make ~amount:n ()) in
        Ok ((),Kom.Message.batch [Kom.Message.encode mixed m])
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in
  let def=definition [Kom.Cell.spec ~id:"check" (Kom.Cell.define (module C));
    Kom.Cell.spec ~id:"c" (counter ~id:"c" ~on_handle:(fun _ -> Atomic.incr calls) ())] in
  with_system def (fun s ->
    let flow=Kom.Flow.sequence [Kom.Flow.step ~id:"choose" ~cell:"check" ~operation:"Choose" ();
      Kom.Flow.branch ~from:(Kom.Flow.output "choose")
        ~default:(step ~id:"nothing" "c" ~input:(Kom.Flow.bind (Kom.Flow.constant value (D.Amount.make ~amount:10 ()))))
        [Kom.Flow.case ~output:(Kom.Flow.constructor mixed ~tag:"Payload")
          (step ~id:"payload" "c" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"choose" ["payload"])))] ] in
    equal [4] (call s (Kom.Flow.inline flow) 4 |> ints);
    equal [14] (call s (Kom.Flow.inline flow) 0 |> ints);
    let batch_flow=Kom.Flow.sequence [Kom.Flow.step ~id:"double" ~cell:"check" ~operation:"Double" ();
      Kom.Flow.branch ~from:(Kom.Flow.field ~from:"double" ["value"])
        ~default:(step ~id:"default" "c") []] in
    (match Kom.System.call s ~flow:(Kom.Flow.inline batch_flow) (amount 1) |> get with
    | T.Completion.Failed p -> check (p.code="Binding" && Atomic.get calls=2) "Batch selected an implicit first output"
    | _ -> failwith "Batch source did not fail"))
let tests=["sequence/bind/instantiate",test_sequence;"variant/default/payload",test_routing;
  "bool/fields",test_bool_and_fields;"nested/repeated/parallel Use",test_use;"Use branch/bind",test_use_branch;
  "cell exclusivity/independence",test_exclusivity;"parallel conflict/determinism",test_parallel_conflict;
  "buffering/migration/rollback",test_update;"Force/state schema",test_force;
  "one-worker child/retry",test_child_retry;"real SQLite rollback/retry",test_sqlite_atomicity;
  "child/resource scope on exception",test_scopes;
  "cross-process pinned Flow recovery",(fun () -> test_recovery "flow");
  "cross-process child identity recovery",(fun () -> test_recovery "child");
  "cross-process immutable Flow history",(fun () -> test_recovery "history");
  "buffer rejection resolves receipt",test_buffer_rejection;
  "Force checks message contracts",test_force_contract;
  "commit idempotency/close buffer",test_commit_identity_and_close;
  "pinned transitive catalog independence",test_pinned_dependencies;
  "heterogeneous payload narrowing/single output",test_narrowing_and_batch]
let ()=List.iter (fun (name,test) -> test ();Printf.printf "PASS %s\n%!" name) tests
