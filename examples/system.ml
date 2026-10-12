open Kom

let flows address =
  List.map
    (fun (operation, input) ->
      Flow.define
        { id= operation ^ "_" ^ address
        ; input
        ; output= [("value", Schema.Int)]
        ; body= operation ^ " @" ^ address } )
    [("add", [("amount", Schema.Int)]); ("read", [])]

let definition =
  System.define
    ~cell_kinds:[Counter_cell.cell]
    ~init_flow:"init"
    ~flows:
      ( Flow.define
          { id= "init"
          ; input= []
          ; output= []
          ; body= "!sequence(!reproduce counter as a !reproduce counter as b)"
          }
      :: (flows "a" @ flows "b") )
    ()
