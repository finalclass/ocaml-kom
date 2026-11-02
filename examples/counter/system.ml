open Kom

let flows address =
  List.map
    (fun operation ->
      Flow.define
        ~id:(operation ^ "_" ^ address)
        ~body:(operation ^ " @" ^ address)
        () )
    ["add"; "read"]

let definition =
  System.define
    ~cell_kinds:[Counter_cell.cell]
    ~init_flow:"init"
    ~flows:
      ( Flow.define
          ~id:"init"
          ~body:
            {|
        !reproduce counter as @a
        !reproduce counter as @b
      |}
          ()
      :: (flows "a" @ flows "b") )
    ()
