let nal_type nal = if nal = "" then 0 else Char.code nal.[0] land 0x1f

(* Packet types of the payload format's own, which occupy the values a NAL unit
   type never takes (RFC 6184 §5.4). *)
let stap_a = 24
let fu_a = 28

let starts_unit payload =
  String.length payload >= 1
  &&
  let indicator = Char.code payload.[0] land 0x1f in
  if indicator = fu_a then
    String.length payload >= 2 && Char.code payload.[1] land 0x80 <> 0
  else (indicator >= 1 && indicator <= 23) || indicator = stap_a

(* An aggregation packet is the indicator byte then a sequence of units, each
   preceded by its sixteen-bit length (RFC 6184 §5.7.1). *)
let rec aggregated payload offset acc =
  let length = String.length payload in
  if offset >= length then List.rev acc
  else if offset + 2 > length then List.rev acc
  else
    let size = String.get_uint16_be payload offset in
    if size = 0 || offset + 2 + size > length then List.rev acc
    else
      aggregated payload (offset + 2 + size)
        (String.sub payload (offset + 2) size :: acc)

let payload_nal_types payload =
  if String.length payload < 1 then []
  else
    match Char.code payload.[0] land 0x1f with
    | n when n >= 1 && n <= 23 -> [ n ]
    | n when n = stap_a -> List.map nal_type (aggregated payload 1 [])
    | n when n = fu_a ->
        (* Only the first fragment of a unit says what the unit is, and only it
           can be joined; the rest continue something already begun. *)
        if String.length payload >= 2 && Char.code payload.[1] land 0x80 <> 0 then
          [ Char.code payload.[1] land 0x1f ]
        else []
    | _ -> []

(* Reassembly -------------------------------------------------------------- *)

type t = {
  fragment : Buffer.t;
  (* Whether the buffer holds a fragment that started properly. A fragment
     joined in the middle cannot be completed, and must not be emitted. *)
  mutable started : bool;
}

let create () = { fragment = Buffer.create 4096; started = false }

let reset t =
  Buffer.clear t.fragment;
  t.started <- false

let push t payload =
  if String.length payload < 1 then []
  else
    let indicator = Char.code payload.[0] in
    match indicator land 0x1f with
    | n when n >= 1 && n <= 23 ->
        (* The packet is the unit. *)
        reset t;
        [ payload ]
    | n when n = stap_a -> 
        reset t;
        aggregated payload 1 []
    | n when n = fu_a ->
        if String.length payload < 2 then []
        else begin
          let header = Char.code payload.[1] in
          let start = header land 0x80 <> 0 in
          let last = header land 0x40 <> 0 in
          let body =
            String.sub payload 2 (String.length payload - 2)
          in
          if start then begin
            Buffer.clear t.fragment;
            (* The unit's own header is rebuilt from the two: the reference
               indication comes from the indicator, the type from the fragment
               header (RFC 6184 §5.8). *)
            Buffer.add_char t.fragment
              (Char.chr ((indicator land 0xe0) lor (header land 0x1f)));
            t.started <- true
          end;
          if not t.started then []
          else begin
            Buffer.add_string t.fragment body;
            if not last then []
            else begin
              let nal = Buffer.contents t.fragment in
              reset t;
              [ nal ]
            end
          end
        end
    | _ ->
        (* Interleaved modes and the single-time aggregation packets that carry
           a timestamp offset; a browser sends neither. *)
        []

(* Storing units in a container --------------------------------------------- *)

let length_prefixed nal =
  let prefix = Bytes.create 4 in
  Bytes.set_int32_be prefix 0 (Int32.of_int (String.length nal));
  Bytes.unsafe_to_string prefix ^ nal

let avcc ~sps ~pps =
  if String.length sps < 4 then invalid_arg "Rtp.H264.avcc: sequence parameter set too short";
  let buffer = Buffer.create 64 in
  let uint16 n =
    Buffer.add_uint8 buffer ((n lsr 8) land 0xff);
    Buffer.add_uint8 buffer (n land 0xff)
  in
  Buffer.add_uint8 buffer 1 (* configuration version *);
  (* The profile, its compatibility flags and the level, copied out of the
     parameter set that follows. *)
  Buffer.add_char buffer sps.[1];
  Buffer.add_char buffer sps.[2];
  Buffer.add_char buffer sps.[3];
  (* Six reserved bits set, then the length of a unit's length field, less
     one: four bytes, as {!length_prefixed} writes. *)
  Buffer.add_uint8 buffer 0xff;
  (* Three reserved bits set, then how many sequence parameter sets follow. *)
  Buffer.add_uint8 buffer 0xe1;
  uint16 (String.length sps);
  Buffer.add_string buffer sps;
  Buffer.add_uint8 buffer 1;
  uint16 (String.length pps);
  Buffer.add_string buffer pps;
  Buffer.contents buffer

(* Reading a sequence parameter set ------------------------------------------ *)

(* Within a NAL unit a byte of 0x03 is inserted wherever the payload would
   otherwise contain a start code; it is not part of the syntax and has to go
   before the bits are read (H.264 §7.4.1.1). *)
let unescape nal =
  let buffer = Buffer.create (String.length nal) in
  let zeros = ref 0 in
  String.iter
    (fun c ->
      if !zeros >= 2 && c = '\x03' then zeros := 0
      else begin
        Buffer.add_char buffer c;
        if c = '\x00' then incr zeros else zeros := 0
      end)
    nal;
  Buffer.contents buffer

exception Truncated

type reader = { data : string; mutable bit : int }

let bit r =
  let byte = r.bit / 8 in
  if byte >= String.length r.data then raise Truncated;
  let value = (Char.code r.data.[byte] lsr (7 - (r.bit mod 8))) land 1 in
  r.bit <- r.bit + 1;
  value

let bits r n =
  let value = ref 0 in
  for _ = 1 to n do
    value := (!value lsl 1) lor bit r
  done;
  !value

(* An unsigned exponential-Golomb code: as many zeros as the value has extra
   bits, then those bits (H.264 §9.1). *)
let ue r =
  let leading = ref 0 in
  while bit r = 0 do
    incr leading;
    if !leading > 32 then raise Truncated
  done;
  if !leading = 0 then 0 else ((1 lsl !leading) lor bits r !leading) - 1

let se r =
  let k = ue r in
  if k land 1 = 1 then (k + 1) / 2 else -(k / 2)

(* A scaling list is read only to be skipped over: nothing beyond its length
   matters here (H.264 §7.3.2.1.1.1). *)
let skip_scaling_list r size =
  let last = ref 8 and next = ref 8 in
  for _ = 1 to size do
    if !next <> 0 then begin
      let delta = se r in
      next := (!last + delta + 256) mod 256
    end;
    if !next <> 0 then last := !next
  done

let dimensions sps =
  match
    let r = { data = unescape sps; bit = 8 (* past the unit's header byte *) } in
    let profile_idc = bits r 8 in
    let _constraints_and_reserved = bits r 8 in
    let _level_idc = bits r 8 in
    let _seq_parameter_set_id = ue r in
    let chroma_format_idc = ref 1 (* 4:2:0 unless the profile says otherwise *) in
    let separate_colour_plane = ref false in
    (* Only the profiles above baseline carry the chroma and scaling syntax. *)
    if
      List.mem profile_idc
        [ 100; 110; 122; 244; 44; 83; 86; 118; 128; 138; 139; 134; 135 ]
    then begin
      chroma_format_idc := ue r;
      if !chroma_format_idc = 3 then separate_colour_plane := bit r = 1;
      let _bit_depth_luma = ue r in
      let _bit_depth_chroma = ue r in
      let _qpprime_y_zero_transform_bypass = bit r in
      if bit r = 1 then
        for i = 0 to (if !chroma_format_idc <> 3 then 8 else 12) - 1 do
          if bit r = 1 then skip_scaling_list r (if i < 6 then 16 else 64)
        done
    end;
    let _log2_max_frame_num = ue r in
    let pic_order_cnt_type = ue r in
    if pic_order_cnt_type = 0 then ignore (ue r)
    else if pic_order_cnt_type = 1 then begin
      let _delta_pic_order_always_zero = bit r in
      let _offset_for_non_ref_pic = se r in
      let _offset_for_top_to_bottom_field = se r in
      let cycle = ue r in
      for _ = 1 to cycle do
        ignore (se r)
      done
    end;
    let _max_num_ref_frames = ue r in
    let _gaps_in_frame_num_allowed = bit r in
    let width_in_mbs = ue r + 1 in
    let height_in_map_units = ue r + 1 in
    let frame_mbs_only = bit r in
    if frame_mbs_only = 0 then ignore (bit r);
    let _direct_8x8_inference = bit r in
    let left, right, top, bottom =
      if bit r = 0 then (0, 0, 0, 0)
      else
        let left = ue r in
        let right = ue r in
        let top = ue r in
        let bottom = ue r in
        (left, right, top, bottom)
    in
    (* Cropping is counted in chroma samples, so how much a unit of it removes
       depends on the subsampling and on whether the picture is a frame or a
       pair of fields (H.264 §7.4.2.1.1). *)
    let unit_x, unit_y =
      if !chroma_format_idc = 0 || !separate_colour_plane then (1, 2 - frame_mbs_only)
      else
        let sub_width = if !chroma_format_idc = 3 then 1 else 2 in
        let sub_height = if !chroma_format_idc = 1 then 2 else 1 in
        (sub_width, sub_height * (2 - frame_mbs_only))
    in
    let width = (width_in_mbs * 16) - (unit_x * (left + right)) in
    let height =
      ((2 - frame_mbs_only) * height_in_map_units * 16) - (unit_y * (top + bottom))
    in
    (width, height)
  with
  | exception _ -> None
  | width, height when width > 0 && height > 0 -> Some (width, height)
  | _ -> None
