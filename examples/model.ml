module D=Demo_contracts.Demo
let read path = let ch=open_in path in
  Fun.protect (fun () -> really_input_string ch (in_channel_length ch)) ~finally:(fun () -> close_in ch)
let schema=Kom.Message.schema ["Demo.cyrograf",Model_schema.source]
let value=Kom.Message.codec ~schema ~name:"Demo.Amount" (module D.Amount)
let pair=Kom.Message.codec ~schema ~name:"Demo.Pair" (module D.Pair)
let condition=Kom.Message.codec ~schema ~name:"Demo.Condition" (module D.Condition)
let decision=Kom.Message.codec ~schema ~name:"Demo.Decision" (module D.Decision)
let mixed=Kom.Message.codec ~schema ~name:"Demo.Mixed" (module D.Mixed)
let get = function Ok x -> x | Error ps -> raise (Kom.Error ps)
let amount n=Kom.Message.encode value (D.Amount.make ~amount:n ())
let decode m=(Kom.Message.decode value m).D.Amount.amount
let completed = function
  | Kom.Types.Completion.Completed batch -> batch.items
  | Failed p -> failwith (p.code ^ ": " ^ p.message)
let call system flow n=Kom.System.call system ~flow (amount n) |> get |> completed
let counter ?(revision="1") ?(state_version=1) ?(init=0)
    ?(restore=fun (s : Kom.Types.StateSnapshot.t) -> Kom.Cell.Restored (int_of_string s.data))
    ?(on_handle=fun _ -> ()) ~id () =
  let module C = struct
    type state=int
    let id=id
    let revision=revision
    let state_version=state_version
    let operations=[Kom.Operation.make ~name:"Add" ~input:value ~outputs:[Kom.Message.type_ value]]
    let init _ _=Ok init
    let handle ctx s ~operation:_ m=
      on_handle ctx;
      let next=s+decode m in Ok (next,Kom.Message.batch [amount next])
    let snapshot s=Ok (string_of_int s)
    let restore _ _ s=restore s
    let release _=()
  end in Kom.Cell.define (module C)
let step ?id ?input cell=Kom.Flow.step ?id ~cell ~operation:"Add" ?input ()
let definition ?(flows=[]) cells=Kom.System.define ~cells ~flows ()
let with_system ?workers ?max_attempts def f=Kom.System.with_ ?workers ?max_attempts def f |> get
let fragment ()=Kom.Flow.define ~id:"prepare" (Kom.Flow.sequence [
  step ~id:"a" "a";
  step ~id:"b" ~input:(Kom.Flow.bind (Kom.Flow.output "a")) "b";
  step ~id:"c" ~input:(Kom.Flow.bind (Kom.Flow.output "b")) "c"])
let child_definition counter = definition [Kom.Cell.spec ~id:"child" counter]
let parent child_def =
  let child_flow=Kom.Flow.inline (step ~id:"child-step" "child") in
  let module C=struct
    type state=unit
    let id="parent"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Run" ~input:value ~outputs:[Kom.Message.type_ value]]
    let init _ _=Ok ()
    let handle ctx () ~operation:_ message=
      let child=Kom.Context.child ctx ~id:"calculator" child_def in
      match Kom.Context.call ctx ~call_id:"calculate" child ~flow:child_flow message with
      | Kom.Types.Completion.Completed batch -> Ok ((),batch)
      | Failed p -> Error p
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in Kom.Cell.define (module C)
