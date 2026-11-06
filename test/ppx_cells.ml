open Ppxlib

let transform source =
  Parse.implementation (Lexing.from_string source)
  |> Ppx_kom.Cell_deriver.mapper#structure
  |> ignore

let valid =
  {|
module Demo = struct
  module State = struct end
  let greet _db (state : State.t) (msg : Input.t Kom.Msg.t) : State.t * Output.t = state, output
  [@@kom.transformer {output=patch}]
end [@@kom.cell]
|}

let cases =
  [ "let greet db state msg = state, msg [@@kom.transformer {output=patch}]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=typo}]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=fresh; remove=[]}]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=patch; ports=[]}]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=patch; typo=true}]"
  ; "let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=patch; id=\"\"}]"
  ; "let join db (s : State.t) (m : Input.t Kom.Msg.t list) : State.t * \
     Output.t = s, output [@@kom.joiner {output=patch}]"
  ; "let route db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * (string * \
     Output.t) = s, output [@@kom.router {output=patch; ports=[\"a\";\"a\"]}]"
  ; "module Demo = struct end [@@kom.cell]"
  ; "module Demo = Other [@@kom.cell]"
  ; "module Demo = struct module State = S let cell = () end [@@kom.cell]"
  ; "module Demo = struct module State = S end [@@kom.cell {typo=1}]"
  ; "let greet_operation = ()\n\
     let greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * Output.t = \
     s, output [@@kom.transformer {output=patch}]"
  ; "let rec greet db (s : State.t) (m : Input.t Kom.Msg.t) : State.t * \
     Output.t = s, output [@@kom.transformer {output=patch}]" ]

let () =
  transform valid ;
  List.iter
    (fun source ->
      match transform source with
      | () -> failwith ("PPX accepted invalid declaration: " ^ source)
      | exception Location.Error _ -> () )
    cases ;
  print_endline
    "PASS PPX diagnostics for invalid cell and operation declarations"
