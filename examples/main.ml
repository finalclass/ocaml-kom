open Example_cells.Model
let print name messages=Printf.printf "%s: [%s]\n%!" name
  (String.concat "; " (List.map (fun m -> string_of_int (decode m)) messages))
let stateful ()=
  let counter=counter ~id:"counter" () in
  with_system (definition [Kom.Cell.spec ~id:"counter" counter]) (fun system ->
    print "stateful/first" (call system (Kom.Flow.inline (step "counter")) 2);
    print "stateful/second" (call system (Kom.Flow.inline (step "counter")) 3))
let routing ()=
  let module Check=struct
    type state=unit
    let id="condition"
    let revision="1"
    let state_version=1
    let operations=[Kom.Operation.make ~name:"Choose" ~input:value ~outputs:[Kom.Message.type_ decision]]
    let init _ _=Ok ()
    let handle _ () ~operation:_ m=
      let v=Kom.Message.decode value m in
      let d=if v.D.Amount.amount>0 then D.Decision.Accepted v else Rejected v in
      Ok ((),Kom.Message.batch [Kom.Message.encode decision d])
    let snapshot ()=Ok "unit"
    let restore _ _ _=Kom.Cell.Restored ()
    let release ()=()
  end in
  let check=Kom.Cell.define (module Check) in
  let flow=Kom.Flow.sequence [Kom.Flow.step ~id:"check" ~cell:"check" ~operation:"Choose" ();
    Kom.Flow.branch ~from:(Kom.Flow.output "check")
      ~default:(step ~id:"review" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"check" ["payload"])) "review") [
      Kom.Flow.case ~output:(Kom.Flow.constructor decision ~tag:"Accepted")
        (step ~id:"accepted" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"check" ["payload"])) "accepted");
      Kom.Flow.case ~output:(Kom.Flow.constructor decision ~tag:"Rejected")
        (step ~id:"rejected" ~input:(Kom.Flow.bind (Kom.Flow.field ~from:"check" ["payload"])) "rejected")]] in
  let def=definition (Kom.Cell.spec ~id:"check" check :: List.map (fun id -> Kom.Cell.spec ~id (counter ~id ())) ["accepted";"rejected";"review"]) in
  with_system def (fun system -> print "routing/accepted" (call system (Kom.Flow.inline flow) 4);
    print "routing/rejected" (call system (Kom.Flow.inline flow) (-2)))
let fragments ()=
  let prepare=fragment () in
  let flow=Kom.Flow.sequence [Kom.Flow.use ~as_:"first" prepare;
    Kom.Flow.use ~as_:"second" ~input:(Kom.Flow.bind (Kom.Flow.output "first")) prepare] in
  let def=definition ~flows:[prepare] (List.map (fun id -> Kom.Cell.spec ~id (counter ~id ())) ["a";"b";"c"]) in
  with_system def (fun system -> print "fragments" (call system (Kom.Flow.inline flow) 1))
let parallel ()=
  let def=definition (List.map (fun id -> Kom.Cell.spec ~id (counter ~id ())) ["left";"right"]) in
  with_system def (fun system -> print "parallel" (call system (Kom.Flow.inline (Kom.Flow.parallel [step "left";step "right"])) 7))
let child ()=
  let def=definition [Kom.Cell.spec ~id:"parent" (parent (child_definition (counter ~id:"child" ())))] in
  with_system ~workers:1 def (fun system ->
    print "child/one-worker" (call system (Kom.Flow.inline (Kom.Flow.step ~cell:"parent" ~operation:"Run" ())) 9))
let ()=match Array.to_list Sys.argv |> List.tl with
  | [] | ["all"] -> stateful (); routing (); fragments (); parallel (); child ()
  | ["stateful"] -> stateful () | ["routing"] -> routing () | ["fragments"] -> fragments ()
  | ["parallel"] -> parallel () | ["child"] -> child ()
  | _ -> failwith "Usage: dune exec examples/main.exe -- [all|stateful|routing|fragments|parallel|child]"
