type value = Yojson.Safe.t

type 'a decoder = value -> ('a, Cyrograf.Error.t) result
type 'a encoder = 'a -> (value, Cyrograf.Error.t) result

let error ~code message = Error (Cyrograf.Error.make ~code message)

let is_finite f = Float.is_finite f

let utf8_sequence_length byte =
  if byte land 0x80 = 0x00 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 0

let validate_utf8 text =
  let length = String.length text in
  let rec loop index =
    if index >= length then true
    else
      let byte = Char.code text.[index] in
      let size = utf8_sequence_length byte in
      if size = 0 then false
      else if index + size > length then false
      else
        let rec continuation ok offset =
          if offset >= size then ok
          else
            let next = Char.code text.[index + offset] in
            continuation (ok && next land 0xC0 = 0x80) (offset + 1)
        in
        if not (continuation true 1) then false
        else
          let code =
            match size with
            | 1 -> byte
            | 2 -> ((byte land 0x1F) lsl 6) lor (Char.code text.[index + 1] land 0x3F)
            | 3 ->
              ((byte land 0x0F) lsl 12)
              lor ((Char.code text.[index + 1] land 0x3F) lsl 6)
              lor (Char.code text.[index + 2] land 0x3F)
            | _ ->
              ((byte land 0x07) lsl 18)
              lor ((Char.code text.[index + 1] land 0x3F) lsl 12)
              lor ((Char.code text.[index + 2] land 0x3F) lsl 6)
              lor (Char.code text.[index + 3] land 0x3F)
          in
          let overlong =
            (size = 2 && code < 0x80)
            || (size = 3 && code < 0x800)
            || (size = 4 && code < 0x10000)
          in
          let surrogate = code >= 0xD800 && code <= 0xDFFF in
          let too_high = code > 0x10FFFF in
          if overlong || surrogate || too_high then false
          else loop (index + size)
  in
  loop 0

let has_leading_bom text =
  String.length text >= 3
  && Char.code text.[0] = 0xEF
  && Char.code text.[1] = 0xBB
  && Char.code text.[2] = 0xBF

let hex_value character =
  match character with
  | '0' .. '9' -> Some (Char.code character - Char.code '0')
  | 'a' .. 'f' -> Some (Char.code character - Char.code 'a' + 10)
  | 'A' .. 'F' -> Some (Char.code character - Char.code 'A' + 10)
  | _ -> None

let strip_leading_zeros text =
  let rec find index =
    if index < String.length text && text.[index] = '0' then find (index + 1)
    else index
  in
  let start = find 0 in
  if start >= String.length text then ""
  else String.sub text start (String.length text - start)

let all_zero text =
  let rec check index =
    index >= String.length text || (text.[index] = '0' && check (index + 1))
  in
  check 0

let zero_from text start =
  let rec check index =
    index >= String.length text || (text.[index] = '0' && check (index + 1))
  in
  check start

let exact_integer_digits lexeme =
  let length = String.length lexeme in
  if length = 0 then error ~code:Cyrograf.Error.Code.invalid_int "empty number"
  else
    let negative, start =
      if lexeme.[0] = '-' then (true, 1) else (false, 0)
    in
    let integer_end = ref start in
    while !integer_end < length
          && lexeme.[!integer_end] >= '0' && lexeme.[!integer_end] <= '9'
    do
      incr integer_end
    done;
    let int_digits = String.sub lexeme start (!integer_end - start) in
    let fraction =
      if !integer_end < length && lexeme.[!integer_end] = '.' then begin
        let stop = ref (!integer_end + 1) in
        while !stop < length && lexeme.[!stop] >= '0' && lexeme.[!stop] <= '9' do
          incr stop
        done;
        let digits = String.sub lexeme (!integer_end + 1) (!stop - !integer_end - 1) in
        Some (digits, !stop)
      end
      else None
    in
    let after_fraction = match fraction with Some (_, stop) -> stop | None -> !integer_end in
    let exponent =
      if after_fraction < length
         && (lexeme.[after_fraction] = 'e' || lexeme.[after_fraction] = 'E')
      then
        let position = ref (after_fraction + 1) in
        let sign = ref 1 in
        if !position < length
           && (lexeme.[!position] = '+' || lexeme.[!position] = '-')
        then begin
          if lexeme.[!position] = '-' then sign := -1;
          incr position
        end;
        let digits_start = !position in
        while !position < length
              && lexeme.[!position] >= '0' && lexeme.[!position] <= '9'
        do
          incr position
        done;
        if !position = digits_start then None
        else
          Some (!sign * int_of_string (String.sub lexeme digits_start (!position - digits_start)))
      else None
    in
    let fraction_digits = match fraction with Some (digits, _) -> digits | None -> "" in
    let mantissa = int_digits ^ fraction_digits in
    let cleaned = strip_leading_zeros mantissa in
    if cleaned = "" then Ok (if negative then "-0" else "0")
    else
      let shift = (match exponent with Some value -> value | None -> 0)
                   - String.length fraction_digits in
      let magnitude =
        if shift >= 0 then
          if String.length cleaned + shift > 16 then None
          else Some (cleaned ^ String.make shift '0')
        else
          let drop = -shift in
          if drop >= String.length cleaned then
            if all_zero cleaned then Some "0" else None
          else
            let kept = String.length cleaned - drop in
            if zero_from cleaned kept then Some (String.sub cleaned 0 kept) else None
      in
      match magnitude with
      | None ->
        error ~code:Cyrograf.Error.Code.int_out_of_range
          (Printf.sprintf "number %s is not an exact integer in range" lexeme)
      | Some digits -> Ok (if negative then "-" ^ digits else digits)

let is_plain_integer lexeme =
  if String.length lexeme = 0 then false
  else
    let rec loop index =
      if index >= String.length lexeme then true
      else
        let character = lexeme.[index] in
        character >= '0' && character <= '9' && loop (index + 1)
    in
    let start = if lexeme.[0] = '-' then 1 else 0 in
    start < String.length lexeme
    && loop start
    && not (String.contains lexeme '.' || String.contains lexeme 'e'
            || String.contains lexeme 'E')

module Wire_int = struct
  type t = int

  let min_safe = -9007199254740991
  let max_safe = 9007199254740991

  let in_range value = value >= min_safe && value <= max_safe

  let to_string value = string_of_int value

  let of_small value =
    if in_range value then Ok value
    else
      error ~code:Cyrograf.Error.Code.int_out_of_range
        (Printf.sprintf "integer %d is outside the Wire v1 range" value)

  let of_string_exact digits =
    match int_of_string_opt digits with
    | Some value -> of_small value
    | None ->
      error ~code:Cyrograf.Error.Code.int_out_of_range
        (Printf.sprintf "integer %s is outside the Wire v1 range" digits)

  let of_float_exact value =
    if is_finite value && Float.is_integer value
       && value >= float_of_int min_safe && value <= float_of_int max_safe
    then Ok (int_of_float value)
    else
      error ~code:Cyrograf.Error.Code.invalid_int
        "expected an exact integer within range"

  let of_lexeme lexeme =
    match exact_integer_digits lexeme with
    | Ok digits -> of_string_exact digits
    | Error _ as error -> error

  let to_yojson value =
    if in_range value then Ok (`Int value)
    else
      error ~code:Cyrograf.Error.Code.int_out_of_range
        (Printf.sprintf "integer %d is outside the Wire v1 range" value)
end

let shrink_double = function
  | `Float number when is_finite number && Float.is_integer number
                       && number >= -9.007199254740992e15
                       && number <= 9.007199254740992e15 ->
    `Int (int_of_float number)
  | other -> other
let scan_json_lexemes text =
  let length = String.length text in
  let numbers = ref [] in
  let add_number lexeme = numbers := lexeme :: !numbers in
  let is_number_char character =
    match character with
    | '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true
    | _ -> false
  in
  let record_number index =
    let stop = ref index in
    while !stop < length && is_number_char text.[!stop] do
      incr stop
    done;
    add_number (String.sub text index (!stop - index));
    !stop
  in
  let rec scan_string index =
    if index >= length then error ~code:Cyrograf.Error.Code.invalid_json "unterminated string"
    else
      let character = text.[index] in
      if character = '"' then Ok (index + 1)
      else if Char.code character < 0x20 then
        error ~code:Cyrograf.Error.Code.invalid_json "unescaped control character in string"
      else if character = '\\' then
        if index + 1 >= length then
          error ~code:Cyrograf.Error.Code.invalid_json "unterminated escape in string"
        else
          (match text.[index + 1] with
           | 'u' ->
             if index + 5 >= length then
               error ~code:Cyrograf.Error.Code.invalid_json "truncated unicode escape"
             else
               let digit position = hex_value text.[position] in
               (match (digit (index + 2), digit (index + 3), digit (index + 4), digit (index + 5)) with
                | Some a, Some b, Some c, Some d ->
                  let code = (a lsl 12) lor (b lsl 8) lor (c lsl 4) lor d in
                  if code >= 0xD800 && code <= 0xDBFF then
                    if index + 11 < length && text.[index + 6] = '\\' && text.[index + 7] = 'u'
                    then
                      (match (hex_value text.[index + 8], hex_value text.[index + 9],
                              hex_value text.[index + 10], hex_value text.[index + 11]) with
                       | Some e, Some f, Some g, Some h ->
                         let low = (e lsl 12) lor (f lsl 8) lor (g lsl 4) lor h in
                         if low >= 0xDC00 && low <= 0xDFFF then scan_string (index + 12)
                         else error ~code:Cyrograf.Error.Code.invalid_json "unpaired surrogate"
                       | _ -> error ~code:Cyrograf.Error.Code.invalid_json "invalid unicode escape")
                    else error ~code:Cyrograf.Error.Code.invalid_json "unpaired surrogate"
                  else if code >= 0xDC00 && code <= 0xDFFF then
                    error ~code:Cyrograf.Error.Code.invalid_json "unpaired surrogate"
                  else scan_string (index + 6)
                | _ -> error ~code:Cyrograf.Error.Code.invalid_json "invalid unicode escape")
           | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> scan_string (index + 2)
           | _ -> error ~code:Cyrograf.Error.Code.invalid_json "invalid escape in string")
      else scan_string (index + 1)
  in
  let rec loop index =
    if index >= length then Ok (List.rev !numbers)
    else
      match text.[index] with
      | '"' -> (match scan_string (index + 1) with
                | Ok next -> loop next
                | Error _ as error -> error)
      | '0' .. '9' | '-' -> loop (record_number index)
      | _ -> loop (index + 1)
  in
  loop 0

let wrap_number lexeme =
  if is_plain_integer lexeme then
    match int_of_string_opt lexeme with
    | Some value -> `Int value
    | None -> `Intlit lexeme
  else `Intlit lexeme

let rec wrap_numbers lexemes value =
  match value with
  | `Assoc fields ->
    let rec loop acc lexemes = function
      | [] -> (List.rev acc, lexemes)
      | (name, item) :: rest ->
        let (wrapped, remaining) = wrap_numbers lexemes item in
        loop ((name, wrapped) :: acc) remaining rest
    in
    let (fields, remaining) = loop [] lexemes fields in
    (`Assoc fields, remaining)
  | `List items ->
    let rec loop acc lexemes = function
      | [] -> (List.rev acc, lexemes)
      | item :: rest ->
        let (wrapped, remaining) = wrap_numbers lexemes item in
        loop (wrapped :: acc) remaining rest
    in
    let (items, remaining) = loop [] lexemes items in
    (`List items, remaining)
  | `Int _ | `Float _ | `Intlit _ ->
    (match lexemes with
     | lexeme :: rest -> (wrap_number lexeme, rest)
     | [] -> (value, []))
  | other -> (other, lexemes)

let round_to_double value =
  match value with
  | `Int i -> `Float (float_of_int i)
  | `Intlit lexeme ->
    (match float_of_string_opt lexeme with
     | Some number -> `Float number
     | None -> `Intlit lexeme)
  | other -> other

let rec canonical_numbers value =
  match value with
  | `Assoc fields -> `Assoc (List.map (fun (name, item) -> (name, canonical_numbers item)) fields)
  | `List items -> `List (List.map canonical_numbers items)
  | `Int _ | `Intlit _ as number -> shrink_double (round_to_double number)
  | `Float _ as number -> shrink_double number
  | other -> other

let rec check_finite value =
  match value with
  | `Assoc fields ->
    let rec loop = function
      | [] -> Ok ()
      | (_, v) :: rest ->
        (match check_finite v with
         | Ok () -> loop rest
         | Error _ as error -> error)
    in
    loop fields
  | `List items ->
    let rec loop = function
      | [] -> Ok ()
      | v :: rest ->
        (match check_finite v with
         | Ok () -> loop rest
         | Error _ as error -> error)
    in
    loop items
  | `Float f when not (is_finite f) ->
    error ~code:Cyrograf.Error.Code.non_finite "non-finite floats are not valid Wire values"
  | `Intlit lexeme ->
    (match float_of_string_opt lexeme with
     | Some f when not (is_finite f) ->
       error ~code:Cyrograf.Error.Code.non_finite "non-finite floats are not valid Wire values"
     | _ -> Ok ())
  | _ -> Ok ()

let rec check_duplicate_keys value =
  match value with
  | `Assoc fields ->
    let names = List.sort String.compare (List.map fst fields) in
    let rec find_duplicate = function
      | a :: (b :: _) when a = b -> Some a
      | _ :: rest -> find_duplicate rest
      | [] -> None
    in
    (match find_duplicate names with
     | Some name ->
       error ~code:Cyrograf.Error.Code.duplicate_key
         (Printf.sprintf "duplicate object key %S" name)
     | None ->
       let rec loop = function
         | [] -> Ok ()
         | (_, v) :: rest ->
           (match check_duplicate_keys v with
            | Ok () -> loop rest
            | Error _ as error -> error)
       in
       loop fields)
  | `List items ->
    let rec loop = function
      | [] -> Ok ()
      | v :: rest ->
        (match check_duplicate_keys v with
         | Ok () -> loop rest
         | Error _ as error -> error)
    in
    loop items
  | _ -> Ok ()

let reject_comments text =
  let length = String.length text in
  let rec loop index in_string =
    if index >= length then Ok ()
    else
      let character = text.[index] in
      if in_string then
        if character = '\\' then loop (index + 2) true
        else if character = '"' then loop (index + 1) false
        else loop (index + 1) true
      else if character = '"' then loop (index + 1) true
      else if character = '/' && index + 1 < length
              && (text.[index + 1] = '/' || text.[index + 1] = '*') then
        error ~code:Cyrograf.Error.Code.invalid_json "comments are not valid Wire JSON"
      else loop (index + 1) false
  in
  loop 0 false

let of_string text =
  if has_leading_bom text then
    error ~code:Cyrograf.Error.Code.invalid_json "a leading byte order mark is not valid Wire input"
  else if not (validate_utf8 text) then
    error ~code:Cyrograf.Error.Code.invalid_json "input is not well-formed UTF-8"
  else
    match scan_json_lexemes text with
    | Error _ as error -> error
    | Ok lexemes ->
      (match reject_comments text with
       | Error _ as error -> error
       | Ok () ->
         (match Yojson.Safe.from_string text with
          | exception Yojson.Json_error message ->
            error ~code:Cyrograf.Error.Code.invalid_json message
          | json ->
            (match check_duplicate_keys json with
             | Error _ as error -> error
             | Ok () ->
               let (value, remaining) = wrap_numbers lexemes json in
               if remaining <> [] then
                 error ~code:Cyrograf.Error.Code.invalid_json "number of numeric literals does not match"
               else check_finite value |> Result.map (fun () -> value))))

let to_string (value : value) = Yojson.Safe.to_string (canonical_numbers value)

let type_error expected value =
  error ~code:Cyrograf.Error.Code.type_mismatch
    (Printf.sprintf "expected %s but found %s" expected
       (Yojson.Safe.to_string value))

let dec_string = function
  | `String s -> Ok s
  | value -> type_error "a string" value

let int_to_string value = Wire_int.to_string value

let dec_int = function
  | `Int i -> Wire_int.of_small i
  | `Intlit lexeme -> Wire_int.of_lexeme lexeme
  | `Float f -> Wire_int.of_float_exact f
  | value -> type_error "an integer" value

let dec_float = function
  | `Float f when is_finite f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | `Intlit lexeme ->
    (match float_of_string_opt lexeme with
     | Some f when is_finite f -> Ok f
     | _ ->
       error ~code:Cyrograf.Error.Code.invalid_float
         "non-finite floats are not valid Wire values")
  | `Float _ ->
    error ~code:Cyrograf.Error.Code.invalid_float "non-finite floats are not valid Wire values"
  | value -> type_error "a number" value

let dec_bool = function
  | `Bool b -> Ok b
  | value -> type_error "a boolean" value

let dec_void = function
  | `Null -> Ok ()
  | value -> type_error "null" value

let dec_record = function
  | `Assoc _ as value -> Ok (canonical_numbers value)
  | value -> type_error "an object" value

let dec_list decode = function
  | `List items ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match decode item with
         | Ok decoded -> loop (index + 1) (decoded :: acc) rest
         | Error e -> Error (Cyrograf.Error.with_segment (string_of_int index) e))
    in
    loop 0 [] items
  | value -> type_error "an array" value

let dec_option decode = function
  | `Null -> Ok None
  | value -> (match decode value with
      | Ok decoded -> Ok (Some decoded)
      | Error _ as error -> error)

let dec_struct arity = function
  | `List items when List.length items = arity -> Ok (Array.of_list items)
  | `List items ->
    error ~code:Cyrograf.Error.Code.unexpected_length
      (Printf.sprintf "expected %d element(s) but found %d" arity
         (List.length items))
  | value -> type_error "a Wire struct array" value

let enc_string s = Ok (`String s)
let enc_bool b = Ok (`Bool b)
let enc_void () = Ok `Null

let enc_int i = Wire_int.to_yojson i

let enc_float f =
  if is_finite f then Ok (`Float f)
  else
    error ~code:Cyrograf.Error.Code.invalid_float "non-finite floats are not valid Wire values"

let enc_record value =
  match check_finite value with
  | Ok () -> Ok value
  | Error _ as error -> error

let enc_list encode items =
  let rec loop acc = function
    | [] -> Ok (`List (List.rev acc))
    | item :: rest ->
      (match encode item with
       | Ok encoded -> loop (encoded :: acc) rest
       | Error _ as error -> error)
  in
  loop [] items

let enc_option encode = function
  | None -> Ok `Null
  | Some value ->
    (match encode value with
     | Ok encoded -> Ok encoded
     | Error _ as error -> error)

let field name = function
  | Ok value -> Ok value
  | Error e -> Error (Cyrograf.Error.with_segment name e)

let index i = function
  | Ok value -> Ok value
  | Error e -> Error (Cyrograf.Error.with_segment (string_of_int i) e)

module Syntax = struct
  let ( let* ) result f = Result.bind result f
  let ( let+ ) result f = Result.map f result
end
