open Yojson.Safe.Util
let with_field name value json =
  `Assoc ((name, value) :: List.remove_assoc name (to_assoc json))
module Todo = System
open Kom
open Cell
open Schema
let empty = `Assoc []
let check condition message = if not condition then failwith message
let expect code f =
  match f () with
  | _ -> failwith ("Expected " ^ code)
  | exception Kom.Error error -> check (error.code=code) (error.code ^ ": " ^ error.message)
let flow ?(input=[]) ?(output=[]) id body = Flow.define {id;input;output;body}
let use env ?(workers=4) ?(storage=Storage.memory) ?(id="test") definition f =
  Eio.Switch.run @@ fun sw ->
  let system = System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~workers ~storage ~id definition in
  Fun.protect (fun () -> f system) ~finally:(fun () -> System.close system)
let call system name = System.call system ~flow:name
let temp_db () = let p=Filename.temp_file "kom-" ".sqlite" in Sys.remove p;p
let cleanup p =
  List.iter (fun suffix -> let path=p^suffix in if Sys.file_exists path then Sys.remove path)
    ["";"-wal";"-shm"];
  Sys.readdir (Filename.dirname p) |> Array.iter (fun name ->
    if String.starts_with ~prefix:(Filename.basename p ^ ".") name && String.ends_with ~suffix:".lock" name
    then Sys.remove (Filename.concat (Filename.dirname p) name))

let test_todo env =
  use env Todo.definition (fun system ->
    check (((call system "list_tasks" empty) |> member "tasks" |> to_list)=[]) "empty Todo";
    expect "Contract" (fun () -> call system "add_task" (`Assoc ["name",`String "  "]));
    let a=call system "add_task" (`Assoc ["name",`String " first "]) in
    let b=call system "add_task" (`Assoc ["name",`String "second"]) in
    check ((a |> member "task_id" |> to_string)="1" && (b |> member "task_id" |> to_string)="2") "allocated IDs";
    check ((a |> member "name" |> to_string)="first") "trim name";
    check (List.length (((call system "list_tasks" empty) |> member "tasks" |> to_list))=2) "list tasks";
    ignore (call system "remove_task" (`Assoc ["task_id",`String "1"]));
    expect "NotFound" (fun () -> call system "read_task" (`Assoc ["task_id",`String "1"]));
    check (List.length (((call system "list_tasks" empty) |> member "tasks" |> to_list))=1) "remove";
    expect "Contract" (fun () -> call system "add_task" (`Assoc ["name",`Int 1]));
    expect "Contract" (fun () -> call system "add_task" (`Assoc ["name",`String "a";"name",`String "b"]));
    expect "Flow" (fun () -> call system "init" empty);
    let catalog=System.catalog system in
    let flows=List.map Flow.of_json (catalog |> member "flows" |> to_list) in
    let restored=System.define ~cell_kinds:[Index_cell.cell;Task_cell.cell;Task_ids_expander_cell.cell;Tasks_collector_cell.cell]
      ~init_flow:"init" ~flows () in
    use env restored (fun s -> check (((call s "list_tasks" empty) |> member "tasks" |> to_list)=[]) "AST import";
      check (System.catalog s = catalog) "catalog changed on AST roundtrip");
    let text=Yojson.Safe.to_string catalog in
    check (not (String.contains text '\000')) "catalog JSON";
    expect "Identity" (fun () -> System.call ~request_id:"~kom:bad" system ~flow:"list_tasks" empty))

let test_schema env =
  let large = `Intlit "123456789012345678901234567890" in
  let nested = `Assoc ["", `List [`Null; `Bool true; large; `Assoc ["name", `String "task"]]] in
  let cases =
    [ "any", Any, [nested; `Null; `String "text"; `Int 1; `Float 1.5; `Bool false; `List []],
        [`Float nan; `Float infinity; `Intlit "1.2"; `Intlit "bad"; `Intlit "/*a*/1"; `Intlit "1/*a*/"; `Intlit " 1"; `Intlit "1 "; `Assoc ["a", `Int 1; "a", `Int 2]]
    ; "null", Null, [`Null], [`String "null"]
    ; "string", String, [`String ""], [`Null; `Int 1]
    ; "int", Int, [`Int 1; large; `Intlit "-0"], [`Float 1.; `String "1"]
    ; "number", Number, [`Int 1; large; `Float 1.5], [`String "1"; `Float infinity]
    ; "bool", Bool, [`Bool false], [`Int 0]
    ; "list", List (Any_of [String; Int; Null]), [`List [`String "a"; large; `Null]], [`List [`Bool true]]
    ; "object", Object ["", String; "note", Optional String],
        [`Assoc ["", `String "a"]; `Assoc ["", `String "b"; "note", `String "n"; "extra", nested]],
        [`Assoc []; `Assoc ["", `String "a"; "note", `Null]]
    ; "dict", Dict (List Number), [`Assoc ["", `List [large]; "x", `List [`Float 1.5]]],
        [`Assoc ["x", `List [`String "bad"]]]
    ; "nullable", Any_of [String; Null], [`String "a"; `Null], [`Bool true]
    ; "optional", Optional String, [`String "a"], [`Null]
    ; "optional-nullable", Optional (Any_of [String; Null]), [`String "a"; `Null], [`Int 1] ]
  in
  let flows = List.map (fun (id, value, _, _) ->
    flow ~input:["value", value] ~output:["value", value] id "!sequence()") cases in
  let define flows = System.define ~cell_kinds:[] ~flows () in
  use env (define flows) (fun system ->
    List.iter (fun (id, _, valid, invalid) ->
      List.iter (fun value ->
        let message = `Assoc ["value", value] in
        check (Yojson.Safe.equal (call system id message) message) ("schema " ^ id)) valid;
      List.iter (fun value -> expect "Contract" (fun () -> call system id (`Assoc ["value", value]))) invalid) cases;
    ignore (call system "optional" empty);
    expect "Contract" (fun () -> call system "null" empty);
    expect "Contract" (fun () -> call system "any" (`Int 1));
    let first = `Assoc ["value", `Assoc ["a", `List [`Int 1; `Int 2]; "b", `String "x"]] in
    let reordered = `Assoc ["value", `Assoc ["b", `String "x"; "a", `List [`Int 1; `Int 2]]] in
    let changed = `Assoc ["value", `Assoc ["b", `String "x"; "a", `List [`Int 2; `Int 1]]] in
    ignore (System.call ~request_id:"json-order" system ~flow:"any" first);
    check (Yojson.Safe.equal (System.call ~request_id:"json-order" system ~flow:"any" reordered) first) "object order changed request identity";
    expect "Identity" (fun () -> System.call ~request_id:"json-order" system ~flow:"any" changed);
    let catalog = System.catalog system in
    let imported = catalog |> member "flows" |> to_list |> List.map Flow.of_json in
    use env (define imported) (fun restored ->
      check (Yojson.Safe.equal catalog (System.catalog restored)) "extended schema AST roundtrip"));
  List.iter (fun value -> expect "Contract" (fun () ->
    flow ~input:["value", value] "invalid" "!sequence()"))
    [Any_of []; List (Optional String); Dict (Optional String); Any_of [Optional String]; Optional (Optional String)];
  expect "Contract" (fun () -> flow ~input:["x", String; "x", Int] "duplicate-schema" "!sequence()");
  let compatible actual expected =
    define [flow ~input:["value", actual] ~output:["value", expected] "connection" "!sequence()"] in
  List.iter (fun (actual, expected) -> ignore (compatible actual expected))
    [Int, Number; String, Any_of [String; Null]; Any_of [Int; String], Any_of [Number; String];
     List Int, List Number; Dict Int, Dict Number; Object [], Dict Any;
     Dict String, Object ["id", Optional String]; Object [], Object ["id", Optional Any]];
  List.iter (fun (actual, expected) -> expect "Contract" (fun () -> compatible actual expected))
    [Any, String; Any_of [Int; String], Number; Number, Int; Optional String, String;
     Object [], Dict String; Dict String, Object ["id", String]; Object [], Object ["id", Optional String]];
  let router = Cell.define {id="typed-router"; state=unit_state; operations=[
    Router {op="choose"; input=["number", Bool]; output=["Number", ["value", Int]; "Text", ["value", String]];
      impl=(fun () message ->
        if message |> member "number" |> to_bool
        then (), ("Number", with_field "value" (`Int 7) message)
        else (), ("Text", with_field "value" (`String "seven") message))};
    Router {op="optional"; input=["number", Bool]; output=["Present", ["value", String]; "Absent", []];
      impl=(fun () message ->
        if message |> member "number" |> to_bool
        then (), ("Present", with_field "value" (`String "present") message)
        else (), ("Absent", message))};
    Router {op="object"; input=[]; output=["Object", ["value", Object []]; "Dict", ["value", Dict Any]];
      impl=(fun () message -> (), ("Object", with_field "value" (`Assoc []) message))} ]} in
  let define flows = System.define ~cell_kinds:[router] ~init_flow:"init" ~flows:
    (flow "init" "!reproduce typed-router as r" :: flows) () in
  let branch = flow ~input:["number", Bool] ~output:["value", Any_of [Int; String]] "branch"
    "!branch(choose @r Number(!sequence()) Text(!sequence()))" in
  let optional = flow ~input:["number", Bool] ~output:["value", Optional Any] "optional"
    "!branch(optional @r Present(!sequence()) Absent(!sequence()))" in
  let equivalent = flow ~output:["value", Dict Any] "equivalent"
    "!branch(object @r Object(!sequence()) Dict(!sequence()))" in
  use env (define [branch; optional; equivalent]) (fun system ->
    check (member "value" (call system "branch" (`Assoc ["number", `Bool true])) = `Int 7) "integer branch";
    check (member "value" (call system "branch" (`Assoc ["number", `Bool false])) = `String "seven") "string branch";
    check (not (List.mem_assoc "value" (to_assoc (call system "optional" (`Assoc ["number", `Bool false]))))) "absent branch";
    ignore (call system "equivalent" empty));
  expect "Contract" (fun () -> define [flow ~input:["number", Bool] ~output:["value", Int] "narrow"
    "!branch(choose @r Number(!sequence()) Text(!sequence()))"]);
  expect "Contract" (fun () -> define [flow ~input:["number", Bool] ~output:["value", Optional String] "unknown"
    "!branch(optional @r Present(!sequence()) Absent(!sequence()))"]);
  let failure = Cell.define {id="util"; state=Recovery_model.state; operations=[
    Transformer {op="bad"; input=["value", Any]; output=[];
      impl=(fun state message -> ignore (message |> member "value" |> to_int); state+1, message)};
    Transformer {op="read"; input=[]; output=["n", Int]; impl=(fun state message -> state, with_field "n" (`Int state) message)} ]} in
  let definition = System.define ~cell_kinds:[failure] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce util as u";
    flow ~input:["value", Any] "bad" "bad @u";
    flow ~output:["n", Int] "read" "read @u"] () in
  use env definition (fun system ->
    expect "Contract" (fun () -> call system "bad" (`Assoc ["value", `String "wrong"]));
    check (call system "read" empty |> member "n" |> to_int = 0) "Yojson error changed state")

let test_groups env =
  let joins=Atomic.make 0 in
  let selected=Atomic.make 0 in
  let cell=Cell.define {id="pipeline";state=unit_state;operations=[
    Expander {op="expand";input=["values",List Int];output=["n",Int];
      impl=(fun () m -> (),List.map (fun n -> `Assoc ["n",n]) (m |> member "values" |> to_list))};
    Expander {op="repeat";input=["n",Int];output=["n",Int];
      impl=(fun () m -> (),List.init (m |> member "n" |> to_int) (fun _ -> m))};
    Joiner {op="join";input=["n",Int];output=["values",List Int];
      impl=(fun () ms -> ignore (Atomic.fetch_and_add joins 1);
        (),`Assoc ["values",`List (List.map (member "n") ms)])};
    Router {op="condition";input=["positive",Bool];output=["True",[];"False",[]];
      impl=(fun () m -> (),((if (m |> member "positive" |> to_bool) then "True" else "False"),m))};
    Transformer {op="yes";input=[];output=["answer",Bool];impl=(fun () m -> ignore (Atomic.fetch_and_add selected 1);(),with_field "answer" (`Bool true) m)};
    Transformer {op="no";input=[];output=["answer",Bool];impl=(fun () m -> ignore (Atomic.fetch_and_add selected 10);(),with_field "answer" (`Bool false) m)};
    Transformer {op="bad";input=["n",Int];output=[];impl=(fun () m -> (),with_field "n" (`Int 9) m)};
    Transformer {op="wrong";input=[];output=["n",Int];impl=(fun () m -> (),with_field "n" (`String "bad") m)};
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
  use env ~workers:1 (define [group;parallel;branch;badport;flow ~input:["n",Int] "bad" "bad @p";flow "wrong" "wrong @p"]) (fun s ->
    let run values=call s "group" (`Assoc ["values",`List (List.map (fun n -> `Int n) values)]) in
    check (((run [2;0;1]) |> member "values" |> to_list)=[`Int 2;`Int 2;`Int 1]) "flatten order with empty subgroup";
    check (((run []) |> member "values" |> to_list)=[]) "join empty group";
    check (Atomic.get joins=2) "join once per group";
    check (((call s "parallel" (`Assoc ["n",`Int 7])) |> member "values" |> to_list)=[`Int 7;`Int 7]) "parallel collection";
    List.iter (fun b -> check (((call s "branch" (`Assoc ["positive",`Bool b])) |> member "answer" |> to_bool)=b) "router selection") [true;false];
    check (Atomic.get selected=11) "unselected branch executed";
    expect "Contract" (fun () -> call s "bad" (`Assoc ["n",`Int 1]));
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
  use env (define [flow "collision" "!reproduce pipeline as p"]) (fun s ->
    expect "CellExists" (fun () -> call s "collision" empty))

let test_concurrency env =
  let entered, enter = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let state=Recovery_model.state in
  let cell=Cell.define {id="counter";state;operations=[
    Transformer {op="inc";input=["wait",Bool];output=["n",Int];impl=(fun n m ->
      if (m |> member "wait" |> to_bool) then (
        Eio.Promise.resolve enter (); Eio.Promise.await released);
      n+1,with_field "n" (`Int (n+1)) m)}
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce counter as a !reproduce counter as b)";
    flow ~input:["wait",Bool] ~output:["n",Int] "a" "inc @a";
    flow ~input:["wait",Bool] ~output:["n",Int] "b" "inc @b"] () in
  use env ~workers:1 definition (fun s -> Eio.Switch.run @@ fun sw ->
    let message = `Assoc ["wait",`Bool true] in
    let first=Eio.Fiber.fork_promise ~sw (fun () -> call s "a" message) in
    Eio.Promise.await entered;
    check (((call s "b" (`Assoc ["wait",`Bool false])) |> member "n" |> to_int)=1) "different cell blocked with workers=1";
    let second=Eio.Fiber.fork_promise ~sw (fun () -> call s "a" (`Assoc ["wait",`Bool false])) in
    Eio.Fiber.yield ();
    check (not (Eio.Promise.is_resolved second)) "same cell ran during IO";
    Eio.Promise.resolve release ();
    let first=Eio.Promise.await_exn first and second=Eio.Promise.await_exn second in
    check ((first |> member "n" |> to_int)=1 && (second |> member "n" |> to_int)=2) "same cell serialization";
    check (message=`Assoc ["wait",`Bool true]) "input message mutated")

let test_order_and_close env =
  let released, release = Eio.Promise.create () and fast_done, fast = Eio.Promise.create () in
  let cell=Cell.define {id="ordered";state=unit_state;operations=[
    Transformer {op="slow";input=[];output=["n",Int];impl=(fun () m ->
      Eio.Promise.await released; (),with_field "n" (`Int 1) m)};
    Transformer {op="fast";input=[];output=["n",Int];impl=(fun () m ->
      Eio.Promise.resolve fast (); (),with_field "n" (`Int 2) m)};
    Joiner {op="join";input=["n",Int];output=["values",List Int];impl=(fun () ms ->
      (),`Assoc ["values",`List (List.map (member "n") ms)])};
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce ordered as slow !reproduce ordered as fast !reproduce ordered as join)";
    flow ~output:["values",List Int] "order" "!sequence(!parallel(slow @slow fast @fast) join @join)";
    flow "ping" "!sequence()"] () in
  use env ~workers:1 definition (fun s -> Eio.Switch.run @@ fun sw ->
    let message = `Assoc ["context", `Assoc ["value", `String "shared"]] in
    let work=Eio.Fiber.fork_promise ~sw (fun () -> call s "order" message) in
    Eio.Promise.await fast_done;
    let closer=Eio.Fiber.fork_promise ~sw (fun () -> System.close s) in
    let rec closing () =
      match call s "ping" empty with
      | _ -> Eio.Fiber.yield ();closing ()
      | exception Kom.Error error -> check (error.code="Closed") "close rejected unexpected error"
    in closing ();
    check (not (Eio.Promise.is_resolved closer)) "close returned before active flow";
    Eio.Promise.resolve release ();
    let result=Eio.Promise.await_exn work in
    Eio.Promise.await_exn closer;
    check ((result |> member "values" |> to_list)=[`Int 1;`Int 2]) "completion order changed collection";
    check (message=`Assoc ["context", `Assoc ["value", `String "shared"]]) "parallel branches changed input";
    expect "Closed" (fun () -> call s "ping" empty))

let test_storage env =
  let path=temp_db () in
  Fun.protect ~finally:(fun () -> cleanup path) (fun () ->
    let definition=Recovery_model.definition () in
    use env ~id:"stored" ~storage:(Kom_sqlite.storage path) definition (fun s ->
      expect "Exception" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~id:"stored" ~storage:(Kom_sqlite.storage path) definition));
      check (((System.call ~request_id:"once" s ~flow:"work" empty) |> member "n" |> to_int)=1) "first request";
      check (((System.call ~request_id:"once" s ~flow:"work" empty) |> member "n" |> to_int)=1) "duplicate request";
      expect "Identity" (fun () -> System.call ~request_id:"once" s ~flow:"read" empty));
    use env ~id:"stored" ~storage:(Kom_sqlite.storage path) definition (fun s ->
      check (((call s "read" empty) |> member "n" |> to_int)=1) "restored state";
      check (((System.call ~request_id:"once" s ~flow:"work" empty) |> member "n" |> to_int)=1) "restored request");
    expect "Catalog" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~id:"stored" ~storage:(Kom_sqlite.storage path) Todo.definition)));
  let path=temp_db () and armed=Atomic.make false in
  let state={version=1;init=(fun () -> ref 0);to_string=(fun n -> string_of_int !n);
    of_string=(fun s -> try let n=int_of_string s in
      if n < 0 then Result.Error "negative" else Ok (ref n) with _ -> Result.Error "bad")} in
  let cell=Cell.define {id="mutable";state;operations=[
    Transformer {op="bad";input=[];output=[];impl=(fun n m -> incr n;Atomic.set armed true;n,m)};
    Transformer {op="invalid";input=[];output=["n",Int];impl=(fun n m -> incr n;n,with_field "n" (`String "bad") m)};
    Transformer {op="codec";input=[];output=[];impl=(fun n m -> n := -1;n,m)};
    Transformer {op="read";input=[];output=["n",Int];impl=(fun n m -> n,with_field "n" (`Int !n) m)}]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce mutable as m";flow "bad" "bad @m";
    flow "invalid" "invalid @m";flow "codec" "codec @m";
    flow ~output:["n",Int] "read" "read @m"] () in
  Fun.protect ~finally:(fun () -> cleanup path) (fun () ->
    let storage=Kom_sqlite.storage ~before_commit:(fun () -> if Atomic.exchange armed false then failwith "injected rollback") path in
    use env ~storage definition (fun s -> expect "Store" (fun () -> call s "bad" empty);
      expect "Contract" (fun () -> call s "invalid" empty);
      expect "State" (fun () -> call s "codec" empty);
      check (((call s "read" empty) |> member "n" |> to_int)=0) "mutated candidate escaped rollback");
    use env ~storage definition (fun s -> check (((call s "read" empty) |> member "n" |> to_int)=0) "SQLite rollback lost"))

let test_codecs env =
  let data=ref None and closes=ref 0 in
  let backend=Storage.backend (fun _ -> {load=(fun () -> !data);save=(fun text -> data:=Some text);close=(fun () -> incr closes)}) in
  let definition=Recovery_model.definition () in
  use env ~storage:backend definition (fun _ -> ());
  let alter f=data:=Some (Yojson.Safe.to_string (f (Yojson.Safe.from_string (Option.get !data)))) in
  let original= !data in
  alter (with_field "format" (`Int 999));expect "Store" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~storage:backend definition));
  data:=original;
  alter (fun root -> let cells=(root |> member "cells" |> to_list) in with_field "cells"
    (`List (List.map (fun c -> if (c |> member "kind" |> to_string)="counter" then with_field "data" (`String "bad") c else c) cells)) root);
  expect "State" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~storage:backend definition));
  check (!closes=3) "failed restore backend cleanup";
  data:=original;
  alter (fun root ->
    let executions = root |> member "executions" |> to_list in
    with_field "executions" (`List (List.map (fun execution ->
      `Assoc (List.remove_assoc "outcome" (to_assoc execution))) executions)) root);
  expect "Contract" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~storage:backend definition));
  data:=original;
  alter (fun root -> `Assoc (List.remove_assoc "catalog" (to_assoc root)));
  expect "Contract" (fun () -> Eio.Switch.run (fun sw -> System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~storage:backend definition));
  let holder=ref None in
  let cell=Cell.define {id="reentrant";state=unit_state;operations=[
    Transformer {op="call";input=[];output=[];impl=(fun () m -> ignore (call (Option.get !holder) "call" m);(),m)}
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce reentrant as r";flow "call" "call @r"] () in
  use env ~workers:1 definition (fun s -> holder:=Some s;expect "Reentrant" (fun () -> call s "call" empty))

let test_eio_lifecycle env =
  let entered, enter = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let cell=Cell.define {id="waiter";state=Recovery_model.state;operations=[
    Transformer {op="inc";input=[];output=["n",Int];impl=(fun n m ->
      Eio.Promise.resolve enter (); Eio.Promise.await released;
      n+1,with_field "n" (`Int (n+1)) m)}]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce waiter as w";
    flow ~output:["n",Int] "inc" "inc @w"] () in
  use env ~workers:1 definition (fun s ->
    ignore (Eio.Fiber.first
      (fun () -> System.call ~request_id:"detached" s ~flow:"inc" empty)
      (fun () -> Eio.Promise.await entered; empty));
    Eio.Promise.resolve release ();
    check (((System.call ~request_id:"detached" s ~flow:"inc" empty) |> member "n" |> to_int)=1)
      "caller cancellation interrupted accepted execution");
  let entered, enter = Eio.Promise.create () in
  let block=Atomic.make true and data=ref None and closes=ref 0 in
  let storage=Storage.backend (fun _ -> {
    load=(fun () -> !data);save=(fun text -> data:=Some text);close=(fun () -> incr closes)}) in
  let cell=Cell.define {id="cancelled";state=Recovery_model.state;operations=[
    Transformer {op="inc";input=[];output=["n",Int];impl=(fun n m ->
      if Atomic.exchange block false then (Eio.Promise.resolve enter ();Eio.Fiber.await_cancel ());
      n+1,with_field "n" (`Int (n+1)) m)}]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!reproduce cancelled as c";
    flow ~output:["n",Int] "inc" "inc @c"] () in
  Eio.Switch.run (fun sw ->
    let ready, ready_u=Eio.Promise.create () and abort, abort_u=Eio.Promise.create () in
    let owner=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Switch.run (fun sw ->
      let s=System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~workers:1 ~storage definition in
      Eio.Promise.resolve ready_u s;
      Eio.Promise.await abort;
      raise Exit)) in
    let s=Eio.Promise.await ready in
    let caller=Eio.Fiber.fork_promise ~sw (fun () ->
      System.call ~request_id:"cancelled" s ~flow:"inc" empty) in
    Eio.Promise.await entered;
    Eio.Promise.resolve abort_u ();
    (try Eio.Promise.await_exn owner with Exit -> ());
    expect "Closed" (fun () -> Eio.Promise.await_exn caller);
    System.close s);
  check (!closes=1) "cancelled scope leaked storage";
  use env ~workers:1 ~storage definition (fun s ->
    check (((System.call ~request_id:"cancelled" s ~flow:"inc" empty) |> member "n" |> to_int)=1)
      "cancelled execution was completed or state escaped");
  check (!closes=2) "reopened runtime leaked storage"

let test_eio_initialization env =
  let opened=ref 0 and closed=ref 0 in
  let storage=Storage.backend (fun _ -> incr opened;
    {load=(fun () -> None);save=(fun _ -> ());close=(fun () -> incr closed)}) in
  let expired=Eio.Switch.run (fun sw -> sw) in
  expect "Exception" (fun () -> System.create ~sw:expired ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~storage Todo.definition);
  check (!opened=0) "create opened storage before checking Switch";
  let entered, enter=Eio.Promise.create () in
  let cell=Cell.define {id="init_wait";state=unit_state;operations=[
    Transformer {op="wait";input=[];output=[];impl=(fun () _ ->
      Eio.Promise.resolve enter ();Eio.Fiber.await_cancel ())}]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce init_wait as w wait @w)"] () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.first
      (fun () -> ignore (System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~workers:1 ~storage definition);
        failwith "cancelled init unexpectedly completed")
      (fun () -> Eio.Promise.await entered));
  check (!opened=1 && !closed=1) "cancelled init leaked storage or deadlocked";
  Eio.Switch.run (fun sw ->
    Eio.Fiber.first
      (fun () -> ignore (System.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~workers:1 ~storage Todo.definition))
      (fun () -> ());
    check (!opened=2 && !closed=2) "cancelled startup leaked runtime before caller Switch ended")

let test_parallel_failure env =
  let entered, enter=Eio.Promise.create () and released, release=Eio.Promise.create () in
  let failed, failure=Eio.Promise.create () and finished=Atomic.make false in
  let cell=Cell.define {id="failure";state=unit_state;operations=[
    Transformer {op="wait";input=[];output=[];impl=(fun () m ->
      Eio.Promise.resolve enter ();Eio.Promise.await released;Atomic.set finished true;(),m)};
    Transformer {op="fail";input=[];output=[];impl=(fun () _ ->
      Eio.Promise.await entered;Eio.Promise.resolve failure ();failwith "branch failure")};
    Joiner {op="join";input=[];output=[];impl=(fun () _ -> (),empty)}
  ]} in
  let definition=System.define ~cell_kinds:[cell] ~init_flow:"init" ~flows:[
    flow "init" "!sequence(!reproduce failure as a !reproduce failure as b)";
    flow "work" "!sequence(!parallel(wait @a fail @b) join @a)"] () in
  use env ~workers:1 definition (fun s -> Eio.Switch.run @@ fun sw ->
    let work=Eio.Fiber.fork_promise ~sw (fun () -> call s "work" empty) in
    Eio.Promise.await failed;
    Eio.Fiber.yield ();
    check (not (Eio.Promise.is_resolved work)) "parallel failure abandoned launched branch";
    Eio.Promise.resolve release ();
    expect "Exception" (fun () -> Eio.Promise.await_exn work);
    check (Atomic.get finished) "parallel failure cancelled launched branch")

let test_eio_domains env =
  use env ~workers:1 (Recovery_model.definition ()) (fun s ->
    let domain_mgr=Eio.Stdenv.domain_mgr env in
    let result=Eio.Domain_manager.run domain_mgr (fun () -> call s "work" empty) in
    check ((result |> member "n" |> to_int)=1) "cross-domain call failed";
    Eio.Domain_manager.run domain_mgr (fun () -> System.close s);
    expect "Closed" (fun () -> call s "read" empty))

let test_sqlite_io env =
  let path=temp_db () in
  Fun.protect ~finally:(fun () -> cleanup path) (fun () ->
    use env ~workers:1 ~storage:(Kom_sqlite.storage path) (Recovery_model.definition ()) (fun s ->
      let other=System.define ~cell_kinds:[] ~flows:[flow "ping" "!sequence()"] () in
      use env ~workers:1 other (fun other -> Eio.Switch.run @@ fun sw ->
        let writer=Sqlite3.db_open path in
        Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close writer)) (fun () ->
          Sqlite3.Rc.check (Sqlite3.exec writer "BEGIN IMMEDIATE");
          let work=ref None in
          Fun.protect ~finally:(fun () -> Sqlite3.Rc.check (Sqlite3.exec writer "COMMIT")) (fun () ->
            work:=Some (Eio.Fiber.fork_promise ~sw (fun () -> call s "read" empty));
            Eio.Fiber.yield ();
            check (not (Eio.Promise.is_resolved (Option.get !work))) "blocked SQLite save finished before writer released";
            check (call other "ping" empty=empty) "SQLite lock blocked unrelated System");
          ignore (Eio.Promise.await_exn (Option.get !work))))))

let test_recovery env =
  let path=temp_db () and marker=Filename.temp_file "kom-ready-" "" in
  Sys.remove marker;
  Fun.protect ~finally:(fun () -> cleanup path;if Sys.file_exists marker then Sys.remove marker) (fun () ->
    let worker=Filename.concat (Filename.dirname Sys.executable_name) "crash_worker.exe" in
    let pid=Unix.create_process worker [|worker;path;marker|] Unix.stdin Unix.stdout Unix.stderr in
    let deadline=Unix.gettimeofday ()+.10. in
    while not (Sys.file_exists marker) && Unix.gettimeofday () < deadline do Eio.Time.sleep (Eio.Stdenv.clock env) 0.01 done;
    if not (Sys.file_exists marker) then (Unix.kill pid Sys.sigkill;ignore (Unix.waitpid [] pid);failwith "worker did not reach second operation");
    Unix.kill pid Sys.sigkill;ignore (Unix.waitpid [] pid);
    use env ~id:"recovery" ~workers:1 ~storage:(Kom_sqlite.storage path) (Recovery_model.definition ()) (fun s ->
      check (((System.call ~request_id:"crashed" s ~flow:"work" empty) |> member "n" |> to_int)=1) "resumed step repeated";
      check (((call s "read" empty) |> member "n" |> to_int)=1) "restored counter"))

let () = Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
    List.iter (fun (name,test) -> test env;Printf.printf "PASS %s\n%!" name)
      ["Eio domains",test_eio_domains;"SQLite nonblocking IO",test_sqlite_io;"Eio initialization",test_eio_initialization;"Eio lifecycle and cancellation",test_eio_lifecycle;"Eio parallel failure",test_parallel_failure;"Todo and AST",test_todo;"JSON schemas and connections",test_schema;"groups and router",test_groups;"Eio concurrency",test_concurrency;"order and close",test_order_and_close;
       "SQLite and rollback",test_storage;"codecs and lifecycle",test_codecs;"SIGKILL recovery",test_recovery])
