type payload = (string * string) list

type path = string

type req =
  | Get of path
  | Post of
      { path: path
      ; payload: payload }

let parse_payload source =
  let hex = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
    | _ -> -1
  in
  let decode value =
    let decoded = Buffer.create (String.length value) in
    let rec loop index =
      if index < String.length value
      then
        match value.[index] with
        | '+' ->
            Buffer.add_char decoded ' ' ;
            loop (index + 1)
        | '%' when index + 2 < String.length value ->
            let high = hex value.[index + 1] in
            let low = hex value.[index + 2] in
            if high >= 0 && low >= 0
            then (
              Buffer.add_char decoded (Char.chr ((high * 16) + low)) ;
              loop (index + 3) )
            else (
              Buffer.add_char decoded '%' ;
              loop (index + 1) )
        | c ->
            Buffer.add_char decoded c ;
            loop (index + 1)
    in
    loop 0 ;
    Buffer.contents decoded
  in
  String.split_on_char '&' source
  |> List.filter (fun field -> field <> "")
  |> List.map (fun field ->
      let name, value =
        match String.index_opt field '=' with
        | None -> (field, "")
        | Some index ->
            ( String.sub field 0 index
            , String.sub field (index + 1) (String.length field - index - 1) )
      in
      (decode name, decode value) )

let read_req input =
  let invalid message = failwith ("Http.read_req: " ^ message) in
  let read_line () =
    let line = input_line input in
    let length = String.length line in
    if length > 0 && line.[length - 1] = '\r'
    then String.sub line 0 (length - 1)
    else line
  in
  let request = read_line () in
  let meth, path =
    match String.split_on_char ' ' request with
    | [m; p; ("HTTP/1.0" | "HTTP/1.1")] when p <> "" -> (m, p)
    | _ -> invalid "invalid request line"
  in
  if meth <> "GET" && meth <> "POST" then invalid "unsupported method" ;
  let rec read_headers headers =
    match read_line () with
    | "" -> List.rev headers
    | line -> (
      match String.index_opt line ':' with
      | Some index when index > 0 ->
          let name = String.sub line 0 index in
          if name <> String.trim name then invalid "invalid header name" ;
          let value =
            String.sub line (index + 1) (String.length line - index - 1)
            |> String.trim
          in
          read_headers ((String.lowercase_ascii name, value) :: headers)
      | _ -> invalid "invalid header" )
  in
  let headers = read_headers [] in
  if List.mem_assoc "transfer-encoding" headers
  then invalid "unsupported Transfer-Encoding" ;
  let length =
    match
      List.filter_map
        (fun (name, value) ->
          if name = "content-length" then Some value else None )
        headers
    with
    | [] -> 0
    | [value]
      when value <> "" && String.for_all (fun c -> c >= '0' && c <= '9') value
      -> (
      match int_of_string_opt value with
      | Some length when length >= 0 -> length
      | _ -> invalid "invalid Content-Length" )
    | _ -> invalid "invalid Content-Length"
  in
  let body = really_input_string input length in
  match meth with
  | "GET" -> Get path
  | "POST" ->
      ( match List.assoc_opt "content-type" headers with
      | None -> ()
      | Some value ->
          let media_type =
            List.hd (String.split_on_char ';' value)
            |> String.trim
            |> String.lowercase_ascii
          in
          if media_type <> "application/x-www-form-urlencoded"
          then invalid "unsupported Content-Type" ) ;
      Post {path; payload= parse_payload body}
  | _ -> invalid "unsupported method"

let send_string ?(status = "200 OK") ~output str =
  let len = str |> String.length |> Int.to_string in
  output_string
    output
    ( "HTTP/1.1 "
    ^ status
    ^ "\r\nContent-Length: "
    ^ len
    ^ "\r\nConnection: close\r\n\r\n"
    ^ str
    ^ "\n" ) ;

  close_out output

let redirect ~output path =
  output_string
    output
    ( "HTTP/1.1 303 See Other\r\nLocation: "
    ^ path
    ^ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" ) ;
  close_out output
