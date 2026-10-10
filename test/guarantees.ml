module Todo = System
open Kom
open Cell
open Schema
let empty = Json.object_ []
let check condition message = if not condition then failwith message
let expect code f =
  match f () with
  | _ -> failwith ("Expected " ^ code)
  | exception Kom.Error error -> check (error.code=code) (error.code ^ ": " ^ error.message)
let flow ?(input=[]) ?(output=[]) id body = Flow.define {id;input;output;body}
let use ?(workers=4) ?(storage=Storage.memory) ?(id="test") definition f =
  let system = System.create ~workers ~storage ~id definition in
  Fun.protect (fun () -> f system) ~finally:(fun () -> System.close system)
let call system name = System.call system ~flow:name
let temp_db () = let p=Filename.temp_file "kom-" ".sqlite" in Sys.remove p;p
let cleanup p =
  List.iter (fun suffix -> let path=p^suffix in if Sys.file_exists path then Sys.remove path)
    ["";"-wal";"-shm"];
  Sys.readdir (Filename.dirname p) |> Array.iter (fun name ->
    if String.starts_with ~prefix:(Filename.basename p ^ ".") name && String.ends_with ~suffix:".lock" name
    then Sys.remove (Filename.concat (Filename.dirname p) name))

let test_todo () =
  use Todo.definition (fun system ->
    check (Json.get_list "tasks" (call system "list_tasks" empty)=[]) "empty Todo";
    expect "Contract" (fun () -> call system "add_task" (Json.object_ ["name",Json.string "  "]));
    let a=call system "add_task" (Json.object_ ["name",Json.string " first "]) in
    let b=call system "add_task" (Json.object_ ["name",Json.string "second"]) in
    check (Json.get_string "task_id" a="1" && Json.get_string "task_id" b="2") "allocated IDs";
    check (Json.get_string "name" a="first") "trim name";
    check (List.length (Json.get_list "tasks" (call system "list_tasks" empty))=2) "list tasks";
    ignore (call system "remove_task" (Json.object_ ["task_id",Json.string "1"]));
    expect "NotFound" (fun () -> call system "read_task" (Json.object_ ["task_id",Json.string "1"]));
    check (List.length (Json.get_list "tasks" (call system "list_tasks" empty))=1) "remove";
    expect "Contract" (fun () -> call system "add_task" (Json.object_ ["name",Json.int 1]));
    expect "Contract" (fun () -> call system "add_task" (`Assoc ["name",`String "a";"name",`String "b"]));
    expect "Flow" (fun () -> call system "init" empty);
    let catalog=System.catalog system in
    let flows=List.map Flow.of_json (Json.get_list "flows" catalog) in
    let restored=System.define ~cell_kinds:[Todo.Index.cell;Todo.Task.cell;Todo.TaskIdsExpander.cell;Todo.TasksCollector.cell]
      ~init_flow:"init" ~flows () in
    use restored (fun s -> check (Json.get_list "tasks" (call s "list_tasks" empty)=[]) "AST import";
      check (System.catalog s = catalog) "catalog changed on AST roundtrip");
    let text=Json.to_string catalog in
    check (not (String.contains text '\000')) "catalog JSON";
    expect "Identity" (fun () -> System.call ~request_id:"~kom:bad" system ~flow:"list_tasks" empty))

let test_groups () =
  let joins=Atomic.make 0 in
  let selected=Atomic.make 0 in
  let cell=Cell.define {id="pipeline";state=unit_state;operations=[
    Expander {op="expand";input=["values",List Int];output=["n",Int];
      impl=(fun () m -> (),List.map (fun n -> Json.object_ ["n",n]) (Json.get_list "values" m))};
    Expander {op="repeat";input=["n",Int];output=["n",Int];
      impl=(fun () m -> (),List.init (Json.get_int "n" m) (fun _ -> m))};
    Joiner {op="join";input=["n",Int];output=["values",List Int];
      impl=(fun () ms -> ignore (Atomic.fetch_and_add joins 1);
        (),Json.object_ ["values",Json.array (List.map (Json.get "n") ms)])};
    Router {op="condition";input=["positive",Bool];output=["True",[];"False",[]];
      impl=(fun () m -> (),((if Json.get_bool "positive" m then "True" else "False"),m))};
    Transformer {op="yes";input=[];output=["answer",Bool];impl=(fun () m -> ignore (Atomic.fetch_and_add selected 1);(),Json.set "answer" (`Bool true) m)};
    Transformer {op="no";input=[];output=["answer",Bool];impl=(fun () m -> ignore (Atomic.fetch_and_add selected 10);(),Json.set "answer" (`Bool false) m)};
    Transformer {op="bad";input=["n",Int];output=[];impl=(fun () m -> (),Json.set "n" (`Int 9) m)};
    Transformer {op="wrong";input=[];output=["n",Int];impl=(fun () m -> (),Json.set "n" (`String "bad") m)};
    Router {op="badport";input=[];output=["True",[];"False",[]];impl=(fun () m -> (),("Other",m))}
  ]} in
  let init=flow "init" "!reproduce pipeline as p" in
  let group=flow ~input:["values",List Int] ~output:["values",List Int] "group"
    "!sequence(expand @p !parallel_each(repeat @p) !flatten join @p)" in
  let parallel=flow ~input:["n",Int] ~output:["values",List Int] "parallel"
    "!sequence(!parallel(!sequence() !sequence()) join @p)" in
  let branch=flow ~input:["positive",Bool] ~output:["answer",Bool] "branch"
    "!branch(condition @p True(yes @p) False(no @p))" in
  let badport=flow "badport" "!branch(badport @p True(!sequence()) False(!sequence()))" in
  let define flows=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:(init::flows) () in
  use ~workers:1 (define [group;parallel;branch;badport;flow ~input:["n",Int] "bad" "bad @p";flow "wrong" "wrong @p"]) (fun s ->
    let run values=call s "group" (Json.object_ ["values",Json.array (List.map Json.int values)]) in
    check (Json.get_list "values" (run [2;0;1])=[`Int 2;`Int 2;`Int 1]) "flatten order with empty subgroup";
    check (Json.get_list "values" (run [])=[]) "join empty group";
    check (Atomic.get joins=2) "join once per group";
    check (Json.get_list "values" (call s "parallel" (Json.object_ ["n",`Int 7]))=[`Int 7;`Int 7]) "parallel collection";
    List.iter (fun b -> check (Json.get_bool "answer" (call s "branch" (Json.object_ ["positive",`Bool b]))=b) "router selection") [true;false];
    check (Atomic.get selected=11) "unselected branch executed";
    expect "Contract" (fun () -> call s "bad" (Json.object_ ["n",`Int 1]));
    expect "Contract" (fun () -> call s "wrong" empty);
    expect "Router" (fun () -> call s "badport" empty));
  expect "Shape" (fun () -> define [flow ~input:["values",List Int] "nested"
    "!sequence(expand @p !parallel_each(repeat @p) join @p)"]);
  expect "Router" (fun () -> define [flow ~input:["positive",Bool] "uncovered" "!branch(condition @p True(!sequence()))"]);
  expect "Router" (fun () -> define [flow ~input:["positive",Bool] "duplicate" "!branch(condition @p True(!sequence()) True(!sequence()) False(!sequence()))"]);
  expect "Contract" (fun () -> define [flow "missing" "expand @p"]);
  expect "Contract" (fun () -> define [flow ~input:["n",Int] "address" "!reproduce pipeline as p.{$.missing}"]);
  expect "Address" (fun () -> define [flow ~input:["n",Int] "address-type" "!reproduce pipeline as p.{$.n}"]);
  expect "Operation" (fun () -> define [flow "operation" "unknown @p"]);
  use (define [flow "collision" "!reproduce pipeline as p"]) (fun s ->
    expect "CellExists" (fun () -> call s "collision" empty))

let test_concurrency () =
  let mutex=Mutex.create () and changed=Condition.create () in
  let entered=ref false and release=ref false in
  let blocked () = Mutex.lock mutex; entered:=true;Condition.broadcast changed;
    while not !release do Condition.wait changed mutex done;Mutex.unlock mutex in
  let state=Recovery_model.state in
  let cell=Cell.define {id="counter";state;operations=[
    Transformer {op="inc";input=["wait",Bool];output=["n",Int];impl=(fun n m ->
      if Json.get_bool "wait" m then blocked ();
      n+1,Json.set "n" (Json.int (n+1)) m)}
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce counter as a !reproduce counter as b)";
    flow ~input:["wait",Bool] ~output:["n",Int] "a" "inc @a";
    flow ~input:["wait",Bool] ~output:["n",Int] "b" "inc @b"] () in
  use ~workers:2 definition (fun s ->
    let result=ref None in
    let first=Thread.create (fun () -> result:=Some (call s "a" (Json.object_ ["wait",`Bool true]))) () in
    Mutex.lock mutex;while not !entered do Condition.wait changed mutex done;Mutex.unlock mutex;
    check (Json.get_int "n" (call s "b" (Json.object_ ["wait",`Bool false]))=1) "different cell blocked";
    let second_result=ref None in
    let second=Thread.create (fun () -> second_result:=Some (call s "a" (Json.object_ ["wait",`Bool false]))) () in
    Mutex.lock mutex;release:=true;Condition.broadcast changed;Mutex.unlock mutex;
    Thread.join first;Thread.join second;
    check (Json.get_int "n" (Option.get !result)=1 && Json.get_int "n" (Option.get !second_result)=2) "same cell serialization")

let test_order_and_close () =
  let mutex=Mutex.create () and changed=Condition.create () in
  let release=ref false and fast_done=ref false in
  let cell=Cell.define {id="ordered";state=unit_state;operations=[
    Transformer {op="slow";input=[];output=["n",Int];impl=(fun () m ->
      Mutex.lock mutex;while not !release do Condition.wait changed mutex done;Mutex.unlock mutex;
      (),Json.set "n" (Json.int 1) m)};
    Transformer {op="fast";input=[];output=["n",Int];impl=(fun () m ->
      Mutex.lock mutex;fast_done:=true;Condition.broadcast changed;Mutex.unlock mutex;
      (),Json.set "n" (Json.int 2) m)};
    Joiner {op="join";input=["n",Int];output=["values",List Int];impl=(fun () ms ->
      (),Json.object_ ["values",Json.array (List.map (Json.get "n") ms)])};
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce ordered as slow !reproduce ordered as fast !reproduce ordered as join)";
    flow ~output:["values",List Int] "order" "!sequence(!parallel(slow @slow fast @fast) join @join)";
    flow "ping" "!sequence()"] () in
  let s=System.create ~workers:2 definition in
  Fun.protect ~finally:(fun () -> System.close s) (fun () ->
    let result=ref None in
    let work=Thread.create (fun () -> result:=Some (call s "order" empty)) () in
    Mutex.lock mutex;while not !fast_done do Condition.wait changed mutex done;Mutex.unlock mutex;
    let closed=Atomic.make false in
    let closer=Thread.create (fun () -> System.close s;Atomic.set closed true) () in
    let deadline=Unix.gettimeofday ()+.5. in
    let rec closing () =
      match call s "ping" empty with
      | _ -> if Unix.gettimeofday () > deadline then failwith "close admission timeout" else (Thread.yield ();closing ())
      | exception Kom.Error error -> check (error.code="Closed") "close rejected unexpected error"
    in closing ();
    check (not (Atomic.get closed)) "close returned before active flow";
    Mutex.lock mutex;release:=true;Condition.broadcast changed;Mutex.unlock mutex;
    Thread.join work;Thread.join closer;
    check (Atomic.get closed) "close did not finish";
    check (Json.get_list "values" (Option.get !result)=[`Int 1;`Int 2]) "completion order changed collection";
    expect "Closed" (fun () -> call s "ping" empty))

let test_storage () =
  let path=temp_db () in
  Fun.protect ~finally:(fun () -> cleanup path) (fun () ->
    let definition=Recovery_model.definition () in
    use ~id:"stored" ~storage:(Kom_sqlite.storage path) definition (fun s ->
      expect "Exception" (fun () -> System.create ~id:"stored" ~storage:(Kom_sqlite.storage path) definition);
      check (Json.get_int "n" (System.call ~request_id:"once" s ~flow:"work" empty)=1) "first request";
      check (Json.get_int "n" (System.call ~request_id:"once" s ~flow:"work" empty)=1) "duplicate request";
      expect "Identity" (fun () -> System.call ~request_id:"once" s ~flow:"read" empty));
    use ~id:"stored" ~storage:(Kom_sqlite.storage path) definition (fun s ->
      check (Json.get_int "n" (call s "read" empty)=1) "restored state";
      check (Json.get_int "n" (System.call ~request_id:"once" s ~flow:"work" empty)=1) "restored request");
    expect "Catalog" (fun () -> System.create ~id:"stored" ~storage:(Kom_sqlite.storage path) Todo.definition));
  let path=temp_db () and armed=Atomic.make false in
  let state={version=1;init=(fun () -> ref 0);to_string=(fun n -> string_of_int !n);
    of_string=(fun s -> try let n=int_of_string s in
      if n < 0 then Result.Error "negative" else Ok (ref n) with _ -> Result.Error "bad")} in
  let cell=Cell.define {id="mutable";state;operations=[
    Transformer {op="bad";input=[];output=[];impl=(fun n m -> incr n;Atomic.set armed true;n,m)};
    Transformer {op="invalid";input=[];output=["n",Int];impl=(fun n m -> incr n;n,Json.set "n" (`String "bad") m)};
    Transformer {op="codec";input=[];output=[];impl=(fun n m -> n := -1;n,m)};
    Transformer {op="read";input=[];output=["n",Int];impl=(fun n m -> n,Json.set "n" (Json.int !n) m)}]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce mutable as m";flow "bad" "bad @m";
    flow "invalid" "invalid @m";flow "codec" "codec @m";
    flow ~output:["n",Int] "read" "read @m"] () in
  Fun.protect ~finally:(fun () -> cleanup path) (fun () ->
    let storage=Kom_sqlite.storage ~before_commit:(fun () -> if Atomic.exchange armed false then failwith "injected rollback") path in
    use ~storage definition (fun s -> expect "Store" (fun () -> call s "bad" empty);
      expect "Contract" (fun () -> call s "invalid" empty);
      expect "State" (fun () -> call s "codec" empty);
      check (Json.get_int "n" (call s "read" empty)=0) "mutated candidate escaped rollback");
    use ~storage definition (fun s -> check (Json.get_int "n" (call s "read" empty)=0) "SQLite rollback lost"))

let test_codecs () =
  let data=ref None and closes=ref 0 in
  let backend=Storage.backend (fun _ -> {load=(fun () -> !data);save=(fun text -> data:=Some text);close=(fun () -> incr closes)}) in
  let definition=Recovery_model.definition () in
  use ~storage:backend definition (fun _ -> ());
  let alter f=data:=Some (Json.to_string (f (Json.of_string (Option.get !data)))) in
  let original= !data in
  alter (Json.set "format" (`Int 999));expect "Store" (fun () -> System.create ~storage:backend definition);
  data:=original;
  alter (fun root -> let cells=Json.get_list "cells" root in Json.set "cells"
    (Json.array (List.map (fun c -> if Json.get_string "kind" c="counter" then Json.set "data" (`String "bad") c else c) cells)) root);
  expect "State" (fun () -> System.create ~storage:backend definition);
  check (!closes=3) "failed restore backend cleanup";
  let holder=ref None in
  let cell=Cell.define {id="reentrant";state=unit_state;operations=[
    Transformer {op="call";input=[];output=[];impl=(fun () m -> ignore (call (Option.get !holder) "call" m);(),m)}
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce reentrant as r";flow "call" "call @r"] () in
  use ~workers:1 definition (fun s -> holder:=Some s;expect "Reentrant" (fun () -> call s "call" empty))

let test_recovery () =
  let path=temp_db () and marker=Filename.temp_file "kom-ready-" "" in
  Sys.remove marker;
  Fun.protect ~finally:(fun () -> cleanup path;if Sys.file_exists marker then Sys.remove marker) (fun () ->
    let worker=Filename.concat (Filename.dirname Sys.executable_name) "crash_worker.exe" in
    let pid=Unix.create_process worker [|worker;path;marker|] Unix.stdin Unix.stdout Unix.stderr in
    let deadline=Unix.gettimeofday ()+.10. in
    while not (Sys.file_exists marker) && Unix.gettimeofday () < deadline do Thread.delay 0.01 done;
    if not (Sys.file_exists marker) then (Unix.kill pid Sys.sigkill;ignore (Unix.waitpid [] pid);failwith "worker did not reach second operation");
    Unix.kill pid Sys.sigkill;ignore (Unix.waitpid [] pid);
    use ~id:"recovery" ~workers:1 ~storage:(Kom_sqlite.storage path) (Recovery_model.definition ()) (fun s ->
      check (Json.get_int "n" (System.call ~request_id:"crashed" s ~flow:"work" empty)=1) "resumed step repeated";
      check (Json.get_int "n" (call s "read" empty)=1) "restored counter"))

let () =
  ignore (Thread.create (fun () -> Thread.delay 30.;prerr_endline "Test timeout";exit 2) ());
  List.iter (fun (name,test) -> test ();Printf.printf "PASS %s\n%!" name)
    ["Todo and AST",test_todo;"groups and router",test_groups;"concurrency",test_concurrency;"order and close",test_order_and_close;
     "SQLite and rollback",test_storage;"codecs and lifecycle",test_codecs;"SIGKILL recovery",test_recovery]
