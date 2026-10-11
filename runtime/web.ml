type request =
  { method_: string
  ; target: string
  ; headers: (string * string) list
  ; body: string }

type response =
  { status: int
  ; headers: (string * string) list
  ; body: string }

let response
    ?(status = 200)
    ?(content_type = "text/html; charset=utf-8")
    ?(headers = [])
    body =
  {status; headers= ("Content-Type", content_type) :: headers; body}

let redirect path = response ~status:303 ~headers:[("Location", path)] ""

let percent_decode ~form value =
  let hex = function
    | '0' .. '9' as c -> Char.code c - 48
    | 'a' .. 'f' as c -> Char.code c - 87
    | 'A' .. 'F' as c -> Char.code c - 55
    | _ -> -1
  in
  let b = Buffer.create (String.length value) in
  let rec loop i =
    if i < String.length value
    then
      match value.[i] with
      | '+' when form ->
          Buffer.add_char b ' ' ;
          loop (i + 1)
      | '%' when i + 2 < String.length value ->
          let a = hex value.[i + 1] and c = hex value.[i + 2] in
          if a < 0 || c < 0 then invalid_arg "Malformed URL encoding" ;
          Buffer.add_char b (Char.chr ((16 * a) + c)) ;
          loop (i + 3)
      | '%' -> invalid_arg "Malformed URL encoding"
      | c ->
          Buffer.add_char b c ;
          loop (i + 1)
  in
  loop 0 ;
  Buffer.contents b

let query source =
  let decode = percent_decode ~form:true in
  String.split_on_char '&' source
  |> List.filter (( <> ) "")
  |> List.map (fun field ->
      match String.index_opt field '=' with
      | None -> (decode field, "")
      | Some i ->
          ( decode (String.sub field 0 i)
          , decode (String.sub field (i + 1) (String.length field - i - 1)) ) )

let encode text =
  String.concat
    ""
    (List.init (String.length text) (fun i ->
         Printf.sprintf "%%%02X" (Char.code text.[i]) ) )

let decode text = percent_decode ~form:false text

let path target = List.hd (String.split_on_char '?' target)
