(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

open Mm

(** Media decoding infrastructure.

    We treat files and streams.
    We separate detection from the actual decoding.
    For files, the decoder detection function is passed a filename and
    an expected content kind.
    For streams, it is passed a MIME type and a content kind.

    In practice, most file decoders will be based on stream decoders,
    with a specific (more precise) detection function. Although
    we cannot force it at this point, we provide some infrastructure
    to help.

    In the short term, the plug infrastructure should provide
    a way to ban / prioritize
    plugins. For example:
      - choose ogg_demuxer when extension = ogg
      - choose mad when extension = mp3
      - choose mad when mime-type = audio/mp3 *)

let log = Log.make ["decoder"]

(** A local file is simply identified by its filename. *)
type file = string

(** A stream is identified by a MIME type. *)
type stream = string

type fps = Decoder_utils.fps = { num : int; den : int }

(* Buffer passed to decoder. This wraps around
   regular buffer, adding:
    - Implicit resampling
    - Implicit audio channel conversion
    - Implicit video resize
    - Implicit fps conversion
    - Implicit content drop *)
type buffer = {
  generator : Generator.t;
  put_pcm : ?field:Frame.field -> samplerate:int -> Content.Audio.data -> unit;
  put_yuva420p : ?field:Frame.field -> fps:fps -> Content.Video.data -> unit;
}

type decoder = {
  decode : buffer -> unit;
  (* [seek x]: Skip [x] main ticks. Returns the number of ticks atcually
     skipped. *)
  seek : int -> int;
}

type input = {
  read : bytes -> int -> int -> int;
  (* Seek to an absolute position in bytes. Returns the current position after
     seeking. *)
  lseek : (int -> int) option;
  tell : (unit -> int) option;
  length : (unit -> int) option;
}

(** A decoder is a filling function and a closing function, called at least when
    filling fails, i.e. the frame is partial. The closing function can be called
    earlier e.g. if the user skips. In most cases, file decoders are wrapped
    stream decoders. *)
type file_decoder_ops = {
  fill : Frame.t -> int;
  (* Return remaining ticks. *)
  fseek : int -> int;
  (* There is a record name clash here.. *)
  close : unit -> unit;
}

type file_decoder =
  metadata:Frame.metadata ->
  ctype:Frame.content_type ->
  string ->
  file_decoder_ops

(** A stream decoder does not "own" any file descriptor, and is generally
    assumed to not allocate resources (in the sense of things that should be
    explicitly managed, not just garbage collected). Hence it does not need a
    close function. *)
type stream_decoder = input -> decoder

type image_decoder = file -> Video.Image.t

(** Decoder description. *)
type decoder_specs = {
  media_type : [ `Audio | `Video | `Audio_video | `Midi ];
  priority : unit -> int;
  file_extensions : unit -> string list option;
  mime_types : unit -> string list option;
  file_type : ctype:Frame.content_type -> string -> Frame.content_type option;
  file_decoder : file_decoder option;
  stream_decoder : (ctype:Frame.content_type -> string -> stream_decoder) option;
}

(** Plugins might define various decoders. In order to be accessed, they should
    also register methods for choosing decoders. *)

let conf_decoder =
  Dtools.Conf.void ~p:(Configure.conf#plug "decoder") "Decoder settings"

let conf_decoders =
  Dtools.Conf.list ~p:(conf_decoder#plug "decoders") ~d:[] "Media decoders."

let f c v =
  match c#get_d with
    | None -> c#set_d (Some [v])
    | Some d -> c#set_d (Some (d @ [v]))

let decoders : decoder_specs Plug.t =
  Plug.create
    ~register_hook:(fun name _ -> f conf_decoders name)
    ~doc:"Available decoders." "Available decoders"

let get_decoders () =
  let f cur name =
    match Plug.get decoders name with
      | Some p -> (name, p) :: cur
      | None ->
          log#severe "Cannot find decoder %s" name;
          cur
  in
  let decoders = List.fold_left f [] conf_decoders#get in
  List.sort
    (fun (_, a) (_, b) -> compare (b.priority ()) (a.priority ()))
    decoders

let conf_image_file_decoders =
  Dtools.Conf.list
    ~p:(conf_decoder#plug "image_file_decoders")
    ~d:[] "Decoders and order used to decode image files."

let image_file_decoders : (file -> Video.Image.t option) Plug.t =
  Plug.create
    ~register_hook:(fun name _ -> f conf_image_file_decoders name)
    ~doc:"Image file decoding methods." "image file decoding"

let get_image_file_decoders () =
  let f cur name =
    match Plug.get image_file_decoders name with
      | Some p -> (name, p) :: cur
      | None ->
          log#severe "Cannot find decoder %s" name;
          cur
  in
  List.fold_left f [] conf_image_file_decoders#get

let conf_debug =
  Dtools.Conf.bool
    ~p:(conf_decoder#plug "debug")
    ~d:false "Maximum debugging information (dev only)"
    ~comments:
      [
        "WARNING: Do not enable unless a developer instructed you to do so!";
        "The debugging mode makes it easier to understand why decoding fails,";
        "but as a side effect it will crash liquidsoap at the end of every";
        "track.";
      ]

let conf_mime_types =
  Dtools.Conf.void
    ~p:(conf_decoder#plug "mime_types")
    "Mime-types used for choosing audio and video file decoders"
    ~comments:
      [
        "When a mime-type is available (e.g. with input.http), it can be used ";
        "to guess which audio stream format is used.";
        "This section contains the listings used for that detection, which you ";
        "might want to tweak if you encounter a new mime-type.";
        "If you feel that new mime-types should be permanently added, please ";
        "contact the developers.";
      ]

let conf_file_extensions =
  Dtools.Conf.void
    ~p:(conf_decoder#plug "file_extensions")
    "File extensions used for guessing audio formats"

let conf_priorities =
  Dtools.Conf.void
    ~p:(conf_decoder#plug "priorities")
    "Priorities used for choosing audio and video file decoders"

let test_file ?(log = log) ?mimes ?extensions fname =
  if not (Sys.file_exists fname) then (
    log#info "File %s does not exist!" (Lang_string.quote_string fname);
    false)
  else (
    let ext_ok =
      match extensions with
        | None -> true
        | Some extensions ->
            let ret =
              try List.mem (Utils.get_ext fname) extensions with _ -> false
            in
            if not ret then
              log#info "Unsupported file extension for %s!"
                (Lang_string.quote_string fname);
            ret
    in
    let mime_ok =
      match (mimes, Liqmagic.file_mime fname) with
        | None, _ -> true
        | _, None -> false
        | Some mimes, Some mime ->
            let mimes =
              List.map
                (fun mime -> List.hd (String.split_on_char ';' mime))
                mimes
            in
            let ret = List.mem mime mimes in
            if not ret then
              log#info "Unsupported MIME type for %s: %s!"
                (Lang_string.quote_string fname)
                mime;
            ret
    in
    ext_ok || mime_ok)

let channel_layout audio =
  Lazy.force Content.(Audio.(get_params audio).Content.channel_layout)

let can_decode_type decoded_type target_type =
  let map_convertible cur (field, target_field) =
    let decoded_field = Frame.Fields.find_opt field decoded_type in
    match decoded_field with
      | None -> cur
      | Some decoded_field when Content.Audio.is_format decoded_field -> (
          Audio_converter.Channel_layout.(
            try
              ignore
                (create
                   (channel_layout decoded_field)
                   (channel_layout target_field));
              Frame.Fields.add field target_field cur
            with _ -> cur))
      | Some decoded_field -> Frame.Fields.add field decoded_field cur
  in
  (* Map content that can be converted and drop content that isn't used *)
  let decoded_type =
    List.fold_left map_convertible Frame.Fields.empty
      (Frame.Fields.bindings target_type)
  in
  Frame.compatible decoded_type target_type

let decoder_modes ctype =
  let has field = Frame.Fields.exists (fun k _ -> k = field) ctype in
  match
    (has Frame.Fields.audio, has Frame.Fields.video, has Frame.Fields.midi)
  with
    | true, true, false -> [`Audio_video]
    | true, false, false -> [`Audio; `Audio_video]
    | false, true, false -> [`Video; `Audio_video]
    | false, false, true -> [`Midi]
    | _ -> []

exception Found of (string * Frame.content_type * decoder_specs)

(** Get a valid decoder creator for [filename]. *)
let get_file_decoder ~metadata ~ctype filename =
  let modes = decoder_modes ctype in
  let decoders =
    List.filter
      (fun (name, specs) ->
        let log = Log.make ["decoder"; String.lowercase_ascii name] in
        specs.file_decoder <> None
        && List.mem specs.media_type modes
        && test_file ~log ?mimes:(specs.mime_types ())
             ?extensions:(specs.file_extensions ()) filename)
      (get_decoders ())
  in
  if decoders = [] then (
    log#important "No decoder available for %s!"
      (Lang_string.quote_string filename);
    None)
  else (
    log#info "Available decoders: %s"
      (String.concat ", "
         (List.map
            (fun (name, specs) ->
              Printf.sprintf "%s (priority: %d)" name (specs.priority ()))
            decoders));
    try
      List.iter
        (fun (name, specs) ->
          log#info "Trying decoder %S" name;
          try
            match specs.file_type ~ctype filename with
              | Some decoded_type ->
                  if can_decode_type decoded_type ctype then
                    raise (Found (name, decoded_type, specs))
                  else
                    log#info
                      "Cannot decode file %s with decoder %s as %s. Detected \
                       content: %s"
                      (Lang_string.quote_string filename)
                      name
                      (Frame.string_of_content_type ctype)
                      (Frame.string_of_content_type decoded_type)
              | None -> ()
          with
            | Found v -> raise (Found v)
            | exn ->
                let bt = Printexc.get_backtrace () in
                Utils.log_exception ~log ~bt
                  (Printf.sprintf "Error while checking file's content: %s"
                     (Printexc.to_string exn)))
        decoders;
      log#important "Available decoders cannot decode %s as %s"
        (Lang_string.quote_string filename)
        (Frame.string_of_content_type ctype);
      None
    with Found (name, decoded_type, specs) ->
      log#info
        "Selected decoder %s for file %s with expected kind %s and detected \
         content %s"
        name
        (Lang_string.quote_string filename)
        (Frame.string_of_content_type ctype)
        (Frame.string_of_content_type decoded_type);
      Some
        ( name,
          fun () -> (Option.get specs.file_decoder) ~metadata ~ctype filename ))

(** Get a valid image decoder creator for [filename]. *)
let get_image_file_decoder filename =
  let ans = ref None in
  try
    List.iter
      (fun (name, decoder) ->
        log#info "Trying method %S for %s..." name
          (Lang_string.quote_string filename);
        match
          try decoder filename
          with e ->
            log#info "Decoder %S failed on %s: %s!" name
              (Lang_string.quote_string filename)
              (Printexc.to_string e);
            None
        with
          | Some img ->
              log#important "Method %S accepted %s." name
                (Lang_string.quote_string filename);
              ans := Some img;
              raise Stdlib.Exit
          | None -> ())
      (get_image_file_decoders ());
    log#important "Unable to decode %s using image decoder(s)!"
      (Lang_string.quote_string filename);
    !ans
  with Exit -> !ans

let get_stream_decoder ~ctype mime =
  let modes = decoder_modes ctype in
  let decoders =
    List.filter
      (fun (_, specs) ->
        specs.stream_decoder <> None
        && List.mem specs.media_type modes
        &&
        match specs.mime_types () with
          | None -> false
          | Some mimes -> (
              try
                ignore
                  (List.find
                     (fun m ->
                       try String.sub m 0 (String.length mime) = mime
                       with Invalid_argument _ -> false)
                     mimes);
                true
              with Not_found -> false))
      (get_decoders ())
  in
  if decoders = [] then (
    log#important
      "Unable to find a decoder for stream mime-type %s with expected content \
       %s!"
      mime
      (Frame.string_of_content_type ctype);
    None)
  else (
    log#info "Available decoders:";
    List.iter
      (fun (name, specs) ->
        log#info "%s (priority: %d)" name (specs.priority ()))
      decoders;
    let name, decoder = List.hd decoders in
    log#info "Selected decoder %s for mime-type %s with expected content %s"
      name mime
      (Frame.string_of_content_type ctype);
    Some ((Option.get decoder.stream_decoder ~ctype) mime))

(** {1 Helpers for defining decoders} *)

let mk_buffer ~ctype generator =
  let audio_handlers = Hashtbl.create 0 in
  let video_handlers = Hashtbl.create 0 in

  let get_audio_handler ~field =
    try Hashtbl.find audio_handlers field
    with Not_found ->
      let handler =
        if Frame.Fields.mem field ctype then (
          let resampler = Decoder_utils.samplerate_converter () in
          let current_channel_converter = ref None in
          let current_dst = ref None in

          let mk_channel_converter dst =
            let c = Decoder_utils.channels_converter dst in
            current_dst := Some dst;
            current_channel_converter := Some c;
            c
          in

          let get_channel_converter () =
            let dst = channel_layout (Frame.Fields.find field ctype) in
            match !current_channel_converter with
              | None -> mk_channel_converter dst
              | Some _ when !current_dst <> Some dst -> mk_channel_converter dst
              | Some c -> c
          in
          fun ~samplerate data ->
            let data, _, _ = resampler ~samplerate data 0 (Audio.length data) in
            let data = (get_channel_converter ()) data in
            let data = Content.Audio.lift_data data in
            Generator.put generator field data)
        else fun ~samplerate:_ _ -> ()
      in
      Hashtbl.add audio_handlers field handler;
      handler
  in

  let get_video_handler ~field =
    try Hashtbl.find video_handlers field
    with Not_found ->
      let handler =
        if Frame.Fields.mem field ctype then (
          let video_resample = Decoder_utils.video_resample () in
          let video_scale =
            let width, height =
              try
                Content.Video.dimensions_of_format
                  (Option.get (Frame.Fields.find_opt Frame.Fields.video ctype))
              with Content.Invalid ->
                (* We might have encoded contents *)
                (Lazy.force Frame.video_width, Lazy.force Frame.video_height)
            in
            Decoder_utils.video_scale ~width ~height ()
          in
          let out_freq =
            Decoder_utils.{ num = Lazy.force Frame.video_rate; den = 1 }
          in
          fun ~fps (data : Content.Video.data) ->
            let data = Array.map video_scale data in
            let data = video_resample ~in_freq:fps ~out_freq data in
            let len = Video.Canvas.length data in
            let data =
              Content.Video.lift_data
                ~length:(Frame_settings.main_of_video len)
                data
            in
            Generator.put generator field data)
        else fun ~fps:_ _ -> ()
      in
      Hashtbl.add video_handlers field handler;
      handler
  in

  let put_pcm ?(field = Frame.Fields.audio) ~samplerate data =
    get_audio_handler ~field ~samplerate data
  in

  let put_yuva420p ?(field = Frame.Fields.video) ~fps data =
    get_video_handler ~field ~fps data
  in

  { generator; put_pcm; put_yuva420p }

let mk_decoder ~filename ~close ~remaining ~buffer decoder =
  let prebuf = Frame.main_of_seconds 0.5 in
  let decoding_done = ref false in

  let remaining frame offset =
    remaining ()
    + Generator.length buffer.generator
    + Frame.position frame - offset
  in

  let fill frame =
    if not !decoding_done then (
      try
        while Generator.length buffer.generator < prebuf do
          decoder.decode buffer
        done
      with e ->
        let bt = Printexc.get_backtrace () in
        Utils.log_exception ~log ~bt
          (Printf.sprintf "Decoding %s ended: %s."
             (Lang_string.quote_string filename)
             (Printexc.to_string e));
        decoding_done := true;
        if conf_debug#get then raise e);

    let offset = Frame.position frame in
    Generator.fill buffer.generator frame;

    try remaining frame offset
    with e ->
      log#info "Error while getting decoder's remaining time: %s"
        (Printexc.to_string e);
      decoding_done := true;
      0
  in

  let fseek len =
    let gen_len = Generator.length buffer.generator in
    if len < 0 || len > gen_len then (
      Generator.clear buffer.generator;
      gen_len + decoder.seek (len - gen_len))
    else (
      (* Seek within the pre-buffered data if possible *)
      Generator.truncate buffer.generator len;
      len)
  in
  { fill; fseek; close }

let file_decoder ~filename ~close ~remaining ~ctype decoder =
  let generator = Generator.create ~log:(log#info "%s") ctype in
  let buffer = mk_buffer ~ctype generator in
  mk_decoder ~filename ~close ~remaining ~buffer decoder

let opaque_file_decoder ~filename ~ctype create_decoder =
  let fd = Unix.openfile filename [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in

  let file_size = (Unix.stat filename).Unix.st_size in
  let proc_bytes = ref 0 in
  let read buf ofs len =
    try
      let i = Unix.read fd buf ofs len in
      proc_bytes := !proc_bytes + i;
      i
    with _ -> 0
  in

  let tell () = Unix.lseek fd 0 Unix.SEEK_CUR in
  let length () = (Unix.fstat fd).Unix.st_size in
  let lseek len = Unix.lseek fd len Unix.SEEK_SET in

  let input =
    { read; tell = Some tell; length = Some length; lseek = Some lseek }
  in

  let generator = Generator.create ~log:(log#info "%s") ctype in
  let buffer = mk_buffer ~ctype generator in
  let decoder = create_decoder input in

  let out_ticks = ref 0 in
  let decode buffer =
    let start = Generator.length buffer.generator in
    decoder.decode buffer;
    let stop = Generator.length buffer.generator in
    out_ticks := !out_ticks + stop - start
  in

  let decoder = { decoder with decode } in

  let remaining () =
    let in_bytes = tell () in

    (* Compute an estimated number of remaining ticks. *)
    if !proc_bytes = 0 then -1
    else (
      let compression = float !out_ticks /. float !proc_bytes in
      let remaining_ticks = float (file_size - in_bytes) *. compression in
      int_of_float remaining_ticks)
  in

  let close () = Unix.close fd in

  mk_decoder ~filename ~close ~remaining ~buffer decoder
